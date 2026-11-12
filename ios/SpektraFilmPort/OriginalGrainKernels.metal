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

// Original Poisson probability law without approximate Gaussian fallback.
// For lambda < 30 use Knuth's product-of-uniforms inversion. The previous
// Float32 *CDF summation* may saturate at 0.999999... due to rounding,
// causing rare false "nonconvergence" for legitimate uniform draws near 1.
// Knuth's product avoids cumulative CDF loss; its distribution is exactly
// Poisson(lambda) (independent of SciPy's random stream).
// For lambda >= 30 retain transformed-rejection PTRS.
// Any genuine bad parameter/iteration exhaustion still increments errors
// and MUST block original-mode export; never conceal failures.
// Four atomic counters: total, invalid lambda, low-rate exhaustion,
// high-rate PTRS exhaustion. The renderer must reject if total > 0.
void filmSamplerFault(device atomic_uint* errors, uint reason) {
    atomic_fetch_add_explicit(&errors[0],1u,memory_order_relaxed);
    atomic_fetch_add_explicit(&errors[reason],1u,memory_order_relaxed);
}

float filmPoisson(float lambda, uint seed, uint x, uint y,
                  uint ch, uint sl, device atomic_uint *errors) {
    if (!(isfinite(lambda)) || lambda < 0.0f) {
        filmSamplerFault(errors,1u);
        return 0.0f;
    }
    if (lambda < 30.0f) {
        // Knuth inversion: N is the number of independent uniforms before
        // their product falls below exp(-lambda). All intermediate values
        // are positive and float32-representable for lambda < 30.
        // A 512-draw cap is > 80 sigma beyond this rate range.
        const float threshold=exp(-lambda);
        float product=1.0f;
        for(uint k=0u;k<512u;k++) {
            product *= filmUniform(seed,x,y,ch,sl,k+1u);
            if(product <= threshold) { return float(k); }
        }
        // True sampler exhaustion (not a numerical CDF saturation).
        filmSamplerFault(errors,2u);
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
    filmSamplerFault(errors,3u);
    return 0.0f;
}

// Opt-in original SciPy two-array RNG path: extract the full image plane
// in row-major C order. Swift then generates *all* Poisson draws, followed
// by *all* Binomial draws, and uploads a shared RGBA32Float particle field.
// This shader does not sample RNG and is intentionally independent of tiles.
kernel void originalFilmSourceExtractChannel(
    texture2d<float, access::read> layer [[texture(0)]],
    constant uint &channel [[buffer(0)]],
    device float *rowMajor [[buffer(1)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x >= layer.get_width() || tid.y >= layer.get_height()) { return; }
    rowMajor[tid.y * layer.get_width() + tid.x] = layer.read(tid)[channel];
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

// Source fast_lognormal_from_mean_std() deterministic mean=1 transform.
// The random z is supplied by either the existing production hash normal
// or our diagnostic texture; Numba prange RNG remains NOT bit-identical.
float originalFilmMicroLognormalFromZ(float z, float stdValue) {
    if (stdValue <= 0.05f) { return 1.0f; }
    const float sigma2 = log(1.0f + stdValue * stdValue);
    const float sigma = sqrt(sigma2);
    const float mu = -0.5f * sigma2;
    return exp(mu + sigma * z);
}

// Diagnostic on real GPU; accepts explicit normals from Python source
// fixtures and uses precisely the same transform as production.
kernel void originalFilmMicroFromNormals(
    texture2d<float, access::read> normalImage [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float &microStd [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=output.get_width() || tid.y>=output.get_height()) { return; }
    float3 normal = normalImage.read(tid).rgb;
    output.write(float4(
        originalFilmMicroLognormalFromZ(normal.r,microStd),
        originalFilmMicroLognormalFromZ(normal.g,microStd),
        originalFilmMicroLognormalFromZ(normal.b,microStd),1.0f), tid);
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
    // Use source scalar transform shared with the exact-input GPU
    // reference test. Source Numba RNG is still a distinct pending task.
    float3 vals;
    for(uint ch=0u;ch<3u;ch++){
        float z=filmNormal(args.seed+7541u,
            args.originX+tid.x,args.originY+tid.y,ch,37u,1u);
        vals[ch]=originalFilmMicroLognormalFromZ(z,args.microSigma);
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


// Test-only sentinel: independent of input textures and Swift parameter ABI.
// If this yields zero on an Intel CI runner, Metal dispatch/output is broken
// before testing the scientific convolution; fail explicitly, never certify.
kernel void originalFilmDebugWriteConstant(
    texture2d<float,access::write> output [[texture(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) { return; }
    output.write(float4(0.25f,0.5f,0.75f,1.0f),tid);
}

// Upstream Young–van Vliet 3rd order IIR. Source:
// spektrafilm/utils/fast_gaussian_filter.py _iir_horizontal/_iir_vertical.
// Four passes retain the original recurrence ordering and endpoint state.
// Each shader invocation owns an entire row or column; no tile boundaries.
struct FilmSourceIIRParams {
    float4 B;
    float4 B1;
    float4 B2;
    float4 B3;
    uint width;
    uint height;
};

kernel void originalFilmIIRHorizontalForward(
    texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::write> output [[texture(1)]],
    constant FilmSourceIIRParams &p [[buffer(0)]],
    uint y [[thread_position_in_grid]]) {
    if (y >= p.height) { return; }
    float3 w1 = input.read(uint2(0,y)).rgb;
    float3 w2 = w1, w3 = w1;
    for (uint x=0u; x<p.width; ++x) {
        float3 value = input.read(uint2(x,y)).rgb;
        float3 w = p.B.rgb*value + p.B1.rgb*w1 +
            p.B2.rgb*w2 + p.B3.rgb*w3;
        output.write(float4(w,1.0f),uint2(x,y));
        w3=w2; w2=w1; w1=w;
    }
}

kernel void originalFilmIIRHorizontalBackward(
    texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::write> output [[texture(1)]],
    constant FilmSourceIIRParams &p [[buffer(0)]],
    uint y [[thread_position_in_grid]]) {
    if (y >= p.height) { return; }
    float3 y1 = input.read(uint2(p.width-1u,y)).rgb;
    float3 y2 = y1, y3 = y1;
    for (int x=int(p.width)-1; x>=0; --x) {
        float3 value = input.read(uint2(uint(x),y)).rgb;
        float3 v = p.B.rgb*value + p.B1.rgb*y1 +
            p.B2.rgb*y2 + p.B3.rgb*y3;
        output.write(float4(v,1.0f),uint2(uint(x),y));
        y3=y2; y2=y1; y1=v;
    }
}

kernel void originalFilmIIRVerticalForward(
    texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::write> output [[texture(1)]],
    constant FilmSourceIIRParams &p [[buffer(0)]],
    uint x [[thread_position_in_grid]]) {
    if (x >= p.width) { return; }
    float3 w1 = input.read(uint2(x,0u)).rgb;
    float3 w2 = w1, w3 = w1;
    for (uint y=0u; y<p.height; ++y) {
        float3 value = input.read(uint2(x,y)).rgb;
        float3 w = p.B.rgb*value + p.B1.rgb*w1 +
            p.B2.rgb*w2 + p.B3.rgb*w3;
        output.write(float4(w,1.0f),uint2(x,y));
        w3=w2; w2=w1; w1=w;
    }
}

kernel void originalFilmIIRVerticalBackward(
    texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::write> output [[texture(1)]],
    constant FilmSourceIIRParams &p [[buffer(0)]],
    uint x [[thread_position_in_grid]]) {
    if (x >= p.width) { return; }
    float3 y1 = input.read(uint2(x,p.height-1u)).rgb;
    float3 y2 = y1, y3 = y1;
    for (int y=int(p.height)-1; y>=0; --y) {
        float3 value = input.read(uint2(x,uint(y))).rgb;
        float3 v = p.B.rgb*value + p.B1.rgb*y1 +
            p.B2.rgb*y2 + p.B3.rgb*y3;
        output.write(float4(v,1.0f),uint2(x,uint(y)));
        y3=y2; y2=y1; y1=v;
    }
}

    

    
// Full-image in-place YVV sweeps. Each row / column is owned by one thread.
// Encoder boundaries enforce ordering between the four directional passes.
// Mixed sigma: B=1 and B1=B2=B3=0 keeps FIR-routed channels unchanged.
kernel void originalFilmIIRHorizontalForwardInPlace(
    texture2d<float,access::read_write> io [[texture(0)]],
    constant FilmSourceIIRParams &p [[buffer(0)]],
    uint y [[thread_position_in_grid]]) {
    if(y>=p.height){return;}
    float3 w1=io.read(uint2(0,y)).rgb;
    float3 w2=w1, w3=w1;
    for(uint x=0u;x<p.width;++x){
        float3 v=io.read(uint2(x,y)).rgb;
        float3 w=p.B.rgb*v+p.B1.rgb*w1+p.B2.rgb*w2+p.B3.rgb*w3;
        io.write(float4(w,1.0f),uint2(x,y));
        w3=w2;w2=w1;w1=w;
    }
}
kernel void originalFilmIIRHorizontalBackwardInPlace(
    texture2d<float,access::read_write> io [[texture(0)]],
    constant FilmSourceIIRParams &p [[buffer(0)]],
    uint y [[thread_position_in_grid]]) {
    if(y>=p.height){return;}
    float3 y1=io.read(uint2(p.width-1u,y)).rgb;
    float3 y2=y1,y3=y1;
    for(int x=int(p.width)-1;x>=0;--x){
        float3 v=io.read(uint2(uint(x),y)).rgb;
        float3 w=p.B.rgb*v+p.B1.rgb*y1+p.B2.rgb*y2+p.B3.rgb*y3;
        io.write(float4(w,1.0f),uint2(uint(x),y));
        y3=y2;y2=y1;y1=w;
    }
}
kernel void originalFilmIIRVerticalForwardInPlace(
    texture2d<float,access::read_write> io [[texture(0)]],
    constant FilmSourceIIRParams &p [[buffer(0)]],
    uint x [[thread_position_in_grid]]) {
    if(x>=p.width){return;}
    float3 w1=io.read(uint2(x,0u)).rgb;
    float3 w2=w1,w3=w1;
    for(uint y=0u;y<p.height;++y){
        float3 v=io.read(uint2(x,y)).rgb;
        float3 w=p.B.rgb*v+p.B1.rgb*w1+p.B2.rgb*w2+p.B3.rgb*w3;
        io.write(float4(w,1.0f),uint2(x,y));
        w3=w2;w2=w1;w1=w;
    }
}
kernel void originalFilmIIRVerticalBackwardInPlace(
    texture2d<float,access::read_write> io [[texture(0)]],
    constant FilmSourceIIRParams &p [[buffer(0)]],
    uint x [[thread_position_in_grid]]) {
    if(x>=p.width){return;}
    float3 y1=io.read(uint2(x,p.height-1u)).rgb;
    float3 y2=y1,y3=y1;
    for(int y=int(p.height)-1;y>=0;--y){
        float3 v=io.read(uint2(x,uint(y))).rgb;
        float3 w=p.B.rgb*v+p.B1.rgb*y1+p.B2.rgb*y2+p.B3.rgb*y3;
        io.write(float4(w,1.0f),uint2(x,uint(y)));
        y3=y2;y2=y1;y1=w;
    }
}

// Per-layer streaming sum and the original source-order microstructure
// multiply/subtract. Never retain three whole-frame dye-cloud textures.
kernel void originalFilmAccumulate(
    texture2d<float,access::read> layer [[texture(0)]],
    texture2d<float,access::read_write> accumulated [[texture(1)]],
    constant uint &first [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=accumulated.get_width()||tid.y>=accumulated.get_height()){return;}
    float3 v=layer.read(tid).rgb;
    if(first==0u){v+=accumulated.read(tid).rgb;}
    accumulated.write(float4(v,1.0f),tid);
}
kernel void originalFilmCompositeAccumulated(
    texture2d<float,access::read_write> accumulated [[texture(0)]],
    texture2d<float,access::read> clump [[texture(1)]],
    uint2 tid [[thread_position_in_grid]]) {
    if(tid.x>=accumulated.get_width()||tid.y>=accumulated.get_height()){return;}
    float3 v=accumulated.read(tid).rgb*clump.read(tid).rgb -
        float3(0.03f,0.03f,0.03f);
    accumulated.write(float4(v,1.0f),tid);
}

// Test-only, real GPU Poisson sampler. Uses production filmPoisson directly:
// no CPU substitute and no source random-sequence parity claim. Explicitly
// verifies the resolved low-rate Float32 CDF stall on an actual iPhone GPU.
struct FilmPoissonDiagnosticParams {
    float lambda;
    uint width;
    uint height;
    uint seed;
};
kernel void originalFilmPoissonDiagnostic(
    device float* samples [[buffer(0)]],
    constant FilmPoissonDiagnosticParams& args [[buffer(1)]],
    device atomic_uint* errors [[buffer(2)]],
    uint tid [[thread_position_in_grid]]) {
    uint n = args.width * args.height;
    if(tid >= n) { return; }
    uint x = tid % args.width;
    uint y = tid / args.width;
    samples[tid] = filmPoisson(
        args.lambda, args.seed, x, y, 0u, 0u, errors
    );
}
