#include <metal_stdlib>
using namespace metal;

// The Spektrafilm source model/grain.py uses 3 measured emulsion layers,
// source-derived n_particles_per_pixel and Poisson/Binomial particle counts.
//
// Poisson thinning is exactly distribution-equivalent to Poisson seeds
// followed by binomial development. The PRNG is NOT the SciPy RNG stream.
// Each kernel acts in native optical density, before paper/scan.
// This file implements the source's reflect Gaussian convolution rather
// than CoreImage's clamped-edge approximation.

struct FilmGrainMetalParams {
    float4 totalRanges;
    float4 maxima[3];
    float4 fractions[3];
    float pixelUM;
    float amount;
    uint seed;
    uint originX;
    uint originY;
    uint width;
    uint height;
    float microSigma;
    float microBlur;
};

struct FilmGrainBlurParams {
    float4 sigmas;
    uint width;
    uint height;
    uint axis;
    uint unused;
};

struct FilmGrainCompositeParams {
    float4 totalRanges;
    float amount;
    uint width;
    uint height;
    uint originX;
    uint originY;
    uint coreX;
    uint coreY;
    uint coreWidth;
    uint coreHeight;
};

uint filmHash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

float filmUniform(uint seed, uint x, uint y, uint channel, uint layer,
                  uint iteration) {
    uint h = filmHash(seed ^ filmHash(x * 0x9e3779b9u) ^
        filmHash(y * 0x85ebca6bu) ^ filmHash(channel * 0xc2b2ae35u) ^
        filmHash(layer * 0x27d4eb2fu) ^ filmHash(iteration * 0x165667b1u));
    // Clamp to open (0,1); 24-bit Float32 division can otherwise round
    // the top hash bucket up to exactly 1 and break inverse-CDF sampling.
    float uniform=(float(h & 0xffffffu)+0.5f)/16777216.0f;
    return clamp(uniform,0.000000059604645f,0.9999998807907104f);
}

float filmNormal(uint seed, uint x, uint y, uint channel, uint layer,
                 uint iteration) {
    float a = filmUniform(seed,x,y,channel,layer,iteration);
    float b = filmUniform(seed,x,y,channel,layer,iteration+1u);
    return sqrt(-2.0f*log(a))*cos(6.283185307179586f*b);
}

float filmLogFactorial(float k) {
    if (k < 2.0f) { return 0.0f; }
    if (k < 30.0f) {
        float value = 0.0f;
        for (int i=2;i<30;i++) {
            if (float(i)>k) { break; }
            value += log(float(i));
        }
        return value;
    }
    float inv=1.0f/k;
    float cube=inv*inv*inv;
    return (k+0.5f)*log(k)-k+0.9189385332046727f +
        inv/12.0f - cube/360.0f + cube*inv*inv/1260.0f;
}

// Exact inverse CDF for Poisson(lambda < 30); PTRS transformed rejection
// with analytic logfactorial for larger rates. No silent Gaussian fallback:
// signal error to the caller if bounded iteration fails, then abort export.
float filmPoisson(float lambda, uint seed, uint x, uint y,
                  uint ch, uint sl, device atomic_uint *errors) {
    if (!(isfinite(lambda)) || lambda < 0.0f) {
        atomic_fetch_add_explicit(errors,1u,memory_order_relaxed);
        return 0.0f;
    }
    if (lambda < 30.0f) {
        float u=filmUniform(seed,x,y,ch,sl,1u);
        float prob=exp(-lambda);
        float cum=prob;
        if (u <= cum) { return 0.0f; }
        for (int k=1;k<512;k++) {
            prob *= lambda / float(k);
            cum += prob;
            if (u<=cum) { return float(k); }
        }
        atomic_fetch_add_explicit(errors,1u,memory_order_relaxed);
        return 0.0f;
    }
    float root=sqrt(lambda);
    float b=0.931f+2.53f*root;
    float a=-0.059f+0.02483f*b;
    float invAlpha=1.1239f+1.1328f/(b-3.4f);
    float vr=0.9277f-3.6224f/(b-2.0f);
    for(uint i=0u;i<128u;i++) {
        float u=filmUniform(seed,x,y,ch,sl,i*2u+3u)-0.5f;
        float v=filmUniform(seed,x,y,ch,sl,i*2u+4u);
        float us=0.5f-abs(u);
        if(us < 0.0000001f) { continue; }
        float k=floor((2.0f*a/us+b)*u+lambda+0.43f);
        if(k<0.0f) { continue; }
        if(us >= 0.07f && v<=vr) { return k; }
        if(us<0.013f && v>us) { continue; }
        float ratio=v*invAlpha/(a/(us*us)+b);
        if(log(max(ratio,1.0e-30f))<=
           -lambda+k*log(lambda)-filmLogFactorial(k)) {
            return k;
        }
    }
    atomic_fetch_add_explicit(errors,1u,memory_order_relaxed);
    return 0.0f;
}

kernel void originalFilmParticles(
    texture2d<float,access::read> layerIn [[texture(0)]],
    texture2d<float,access::write> layerOut [[texture(1)]],
    constant FilmGrainMetalParams& args [[buffer(0)]],
    device atomic_uint* errors [[buffer(1)]],
    constant uint& sublayer [[buffer(2)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=args.width || tid.y>=args.height) { return; }
    float3 normalized=layerIn.read(tid).rgb;
    float3 maxD=args.maxima[sublayer].rgb;
    float3 fractions=args.fractions[sublayer].rgb;
    float3 dm=fractions*float3(0.03f,0.03f,0.03f);
    float3 fullMax=maxD+dm;
    float3 p=clamp((clamp(normalized,0.0f,1.0f)*maxD+dm)/
                    max(fullMax,float3(1.0e-8f)),1.0e-6f,1.0f-1.0e-6f);
    float3 sat=1.0f-p*float3(0.97f,0.99f,0.97f)*(1.0f-1.0e-6f);
    const float scales[3]={2.0f,1.0f,0.5f};
    float3 n=args.pixelUM*args.pixelUM*fractions /
        (0.2f*float3(1.6f,1.6f,3.2f)*scales[sublayer]);
    float3 rate=n*p/sat;
    float3 count;
    for(uint ch=0u;ch<3u;ch++){
        count[ch]=filmPoisson(rate[ch],args.seed,
            args.originX+tid.x,args.originY+tid.y,
            ch,sublayer,errors);
    }
    float3 particle=fullMax/max(n,float3(1.0e-8f))*sat*count;
    layerOut.write(float4(particle,1.0f),tid);
}

kernel void originalFilmMicroClump(
    texture2d<float,access::write> output [[texture(0)]],
    constant FilmGrainMetalParams& args [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=args.width||tid.y>=args.height) { return; }
    if(args.microSigma<=0.05f) {
        output.write(float4(1.0f),tid);
        return;
    }
    // Source fast_lognormal_from_mean_std(mean=1,std=30 nm/pixelUM).
    float sig2=log(1.0f+args.microSigma*args.microSigma);
    float sigma=sqrt(sig2);
    float mu=-0.5f*sig2;
    float3 vals;
    for(uint ch=0u;ch<3u;ch++){
        vals[ch]=exp(mu+sigma*filmNormal(args.seed+7541u,
            args.originX+tid.x,args.originY+tid.y,ch,37u,1u));
    }
    output.write(float4(vals,1.0f),tid);
}

int filmReflect(int x,int n) {
    if(n<=1) { return 0; }
    int period=2*n;
    int a=x%period;
    if(a<0) { a+=period; }
    return a<n ? a : (period-1-a);
}

kernel void originalFilmGaussianReflect(
    texture2d<float,access::read> imageIn [[texture(0)]],
    texture2d<float,access::write> imageOut [[texture(1)]],
    constant FilmGrainBlurParams& args [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=args.width||tid.y>=args.height) { return; }
    float3 result=0.0f;
    for(int ch=0;ch<3;ch++){
        float sigma=args.sigmas[ch];
        if(sigma<=0.0f) {
            result[ch]=imageIn.read(tid)[ch];
            continue;
        }
        int radius=int(floor(3.0f*sigma+0.5f));
        float sum=0.0f;
        float weights=0.0f;
        for(int i=-radius;i<=radius;i++){
            int xx=int(tid.x);
            int yy=int(tid.y);
            if(args.axis==0u) { xx=filmReflect(xx+i,int(args.width)); }
            else { yy=filmReflect(yy+i,int(args.height)); }
            float w=exp(-0.5f*pow(float(i)/sigma,2.0f));
            sum+=imageIn.read(uint2(uint(xx),uint(yy)))[ch]*w;
            weights+=w;
        }
        result[ch]=sum/max(weights,1.0e-20f);
    }
    imageOut.write(float4(result,1.0f),tid);
}

kernel void originalFilmCombine(
    texture2d<float,access::read> particle0 [[texture(0)]],
    texture2d<float,access::read> particle1 [[texture(1)]],
    texture2d<float,access::read> particle2 [[texture(2)]],
    texture2d<float,access::read> clump [[texture(3)]],
    texture2d<float,access::write> output [[texture(4)]],
    constant FilmGrainMetalParams& args [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=args.width||tid.y>=args.height){return;}
    float3 particles=particle0.read(tid).rgb +
        particle1.read(tid).rgb + particle2.read(tid).rgb;
    float3 density=particles*clump.read(tid).rgb -
        float3(0.03f,0.03f,0.03f);
    output.write(float4(density,1.0f),tid);
}

kernel void originalFilmWriteCore(
    texture2d<float,access::read> original [[texture(0)]],
    texture2d<float,access::read> grain [[texture(1)]],
    texture2d<float,access::write> destination [[texture(2)]],
    constant FilmGrainCompositeParams& args [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=args.coreWidth||tid.y>=args.coreHeight){return;}
    uint2 tile=uint2(args.coreX+tid.x,args.coreY+tid.y);
    float3 baseline=original.read(tile).rgb*args.totalRanges.rgb;
    float3 developed=grain.read(tile).rgb;
    float3 result=clamp(baseline+args.amount*(developed-baseline),
                       float3(0.0f),args.totalRanges.rgb);
    destination.write(float4(result/args.totalRanges.rgb,1.0f),
                      uint2(args.originX+tid.x,args.originY+tid.y));
}

// Native test-only probe to verify texture binding and Swift/Metal ABI.
// Not invoked by the production rendering pipeline.
kernel void originalFilmDebugProbe(
    texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::write> output [[texture(1)]],
    constant FilmGrainBlurParams& args [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=args.width || tid.y>=args.height){ return; }
    float value=input.read(tid).r;
    output.write(float4(value,args.sigmas.x,float(args.width),1.0f),tid);
}
