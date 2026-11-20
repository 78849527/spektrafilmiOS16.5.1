import SwiftUI
import UIKit

/// Interactive RAW crop view. The pictured image is the uncropped LibRaw
/// source-orientation optical preview, NOT Apple JPEG or an already cropped
/// result. Stored selection is a rectangle in ORIGINAL decoder coordinates.
/// No optical stage is invoked while dragging handles.
struct Build141RAWCropSheet:View {
    @ObservedObject var model:PhotoEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var rect:CGRect
    @State private var dragOrigin:CGRect?
    @State private var proportion:Proportion = .free
    @State private var error:String?

    private enum Proportion:String,CaseIterable,Identifiable {
        case free="自由",original="原比例",square="1:1"
        case portrait="3:4",landscape="4:3"
        case tall="9:16",wide="16:9"
        var id:String {rawValue}
        func value(_ sourceRatio:CGFloat)->CGFloat? {
            switch self {
            case .free:return nil
            case .original:return sourceRatio
            case .square:return 1
            case .portrait:return 3.0/4.0
            case .landscape:return 4.0/3.0
            case .tall:return 9.0/16.0
            case .wide:return 16.0/9.0
            }
        }
    }

    private enum Corner:CaseIterable {
        case upperLeft,upperRight,lowerLeft,lowerRight
        var onLeft:Bool {self == .upperLeft || self == .lowerLeft}
        var onTop:Bool {self == .upperLeft || self == .upperRight}
    }

    init(model:PhotoEditorModel) {
        self.model=model
        if let crop=model.rawCropSelection,
           crop.sourceWidth>0,crop.sourceHeight>0 {
            _rect=State(initialValue:CGRect(
                x:CGFloat(crop.x)/CGFloat(crop.sourceWidth),
                y:CGFloat(crop.y)/CGFloat(crop.sourceHeight),
                width:CGFloat(crop.width)/CGFloat(crop.sourceWidth),
                height:CGFloat(crop.height)/CGFloat(crop.sourceHeight)
            ))
        } else {
            _rect=State(initialValue:CGRect(x:0.06,y:0.06,
                                            width:0.88,height:0.88))
        }
    }

    private var sw:CGFloat {CGFloat(max(1,model.rawCropReferenceWidth))}
    private var sh:CGFloat {CGFloat(max(1,model.rawCropReferenceHeight))}
    private var normalizedAspect:CGFloat? {
        proportion.value(sw/sh).map{$0*sh/sw}
    }

    private func selectProportion(_ value:Proportion) {
        proportion=value
        guard let ratio=normalizedAspect,ratio>0 else{return}
        let cx=rect.midX,cy=rect.midY
        var w=min(0.95,rect.width),h=min(0.95,rect.height)
        if w/h>ratio {w=h*ratio} else {h=w/ratio}
        rect=CGRect(x:max(0,min(1-w,cx-w/2)),
                    y:max(0,min(1-h,cy-h/2)),
                    width:w,height:h)
    }

    private func moved(_ shift:CGSize,canvas:CGSize) {
        guard canvas.width>0,canvas.height>0 else{return}
        let base=dragOrigin ?? rect
        let dx=shift.width/canvas.width,dy=shift.height/canvas.height
        rect.origin.x=max(0,min(1-base.width,base.minX+dx))
        rect.origin.y=max(0,min(1-base.height,base.minY+dy))
        rect.size=base.size
    }

    private func resized(_ corner:Corner,shift:CGSize,canvas:CGSize) {
        guard canvas.width>0,canvas.height>0 else{return}
        let base=dragOrigin ?? rect
        let fixedX=corner.onLeft ? base.maxX : base.minX
        let fixedY=corner.onTop ? base.maxY : base.minY
        let movingX=(corner.onLeft ? base.minX : base.maxX) +
            shift.width/canvas.width
        let movingY=(corner.onTop ? base.minY : base.maxY) +
            shift.height/canvas.height
        let maxW=corner.onLeft ? fixedX : 1-fixedX
        let maxH=corner.onTop ? fixedY : 1-fixedY
        var w=min(maxW,max(0.05,abs(movingX-fixedX)))
        var h=min(maxH,max(0.05,abs(movingY-fixedY)))
        if let ratio=normalizedAspect,ratio>0 {
            w=min(w,h*ratio)
            h=w/ratio
            if h>maxH {h=maxH;w=h*ratio}
        }
        rect=CGRect(x:corner.onLeft ? fixedX-w : fixedX,
                    y:corner.onTop ? fixedY-h : fixedY,
                    width:w,height:h)
    }

    private func handle(_ corner:Corner,canvas:CGSize)->some View {
        let px=(corner.onLeft ? rect.minX : rect.maxX)*canvas.width
        let py=(corner.onTop ? rect.minY : rect.maxY)*canvas.height
        return Circle()
            .fill(Color.white)
            .frame(width:18,height:18)
            .overlay(Circle().stroke(Color.black,lineWidth:1.5))
            .frame(width:36,height:36)
            .contentShape(Rectangle())
            .position(x:px,y:py)
            .gesture(
                DragGesture(minimumDistance:1)
                    .onChanged { value in
                        if dragOrigin==nil {dragOrigin=rect}
                        resized(corner,shift:value.translation,canvas:canvas)
                    }
                    .onEnded { _ in dragOrigin=nil }
            )
            .accessibilityLabel("调整裁切区域角点")
    }

    private func cropCanvas(_ image:UIImage,size:CGSize)->some View {
        let scale=min(size.width/sw,size.height/sh)
        let canvas=CGSize(width:sw*scale,height:sh*scale)
        return ZStack(alignment:.topLeading) {
            Image(uiImage:image)
                .resizable()
                .interpolation(.high)
                .frame(width:canvas.width,height:canvas.height)
            Path { p in
                p.addRect(CGRect(origin:.zero,size:canvas))
                p.addRect(CGRect(
                    x:rect.minX*canvas.width,y:rect.minY*canvas.height,
                    width:rect.width*canvas.width,
                    height:rect.height*canvas.height
                ))
            }
            .fill(Color.black.opacity(0.5),style:FillStyle(eoFill:true))
            .allowsHitTesting(false)
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width:rect.width*canvas.width,
                       height:rect.height*canvas.height)
                .overlay(Rectangle().stroke(Color.white,lineWidth:1.4))
                .position(x:rect.midX*canvas.width,
                          y:rect.midY*canvas.height)
                .gesture(
                    DragGesture(minimumDistance:2)
                        .onChanged { value in
                            if dragOrigin==nil {dragOrigin=rect}
                            moved(value.translation,canvas:canvas)
                        }
                        .onEnded { _ in dragOrigin=nil }
                )
                .accessibilityLabel("拖动裁切区域")
            ForEach(0..<Corner.allCases.count,id:\.self) { index in
                handle(Corner.allCases[index],canvas:canvas)
            }
        }
        .frame(width:canvas.width,height:canvas.height)
        .frame(maxWidth:.infinity,maxHeight:.infinity)
    }

    var body:some View {
        VStack(spacing:11) {
            HStack {
                Text("RAW 冲印前裁切")
                    .font(.headline)
                Spacer()
                Button("取消") {dismiss()}
            }
            .padding(.horizontal,14)
            Text("拖动白框移动，拖动四角调整。裁切在完整 Float64 冲印之前；不修改 DNG/RAF 原片。")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal,14)
            if let preview=model.rawCropReferencePreview {
                GeometryReader { size in
                    cropCanvas(preview,size:size.size)
                }
                .frame(maxHeight:.infinity)
                .background(Color.black)
            } else {
                Text("请先生成未裁切的 RAW 精细预览")
                    .frame(maxHeight:.infinity)
            }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:7) {
                    ForEach(Proportion.allCases) { preset in
                        Button(preset.rawValue) {selectProportion(preset)}
                            .font(.caption)
                            .padding(.horizontal,10).padding(.vertical,7)
                            .background(proportion==preset ?
                                Color.accentColor.opacity(0.18) :
                                Color.secondary.opacity(0.12),
                                in:Capsule())
                    }
                }
                .padding(.horizontal,14)
            }
            Text("裁切约 \(Int(sw*rect.width))×\(Int(sh*rect.height)) px；完整冲印仅处理框内区域。光晕、DIR 和颗粒的边界效果可能与全图冲印后裁切不同。")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal,14)
            if let error {
                Text(error).font(.caption).foregroundColor(.red)
                    .padding(.horizontal,14)
            }
            HStack(spacing:14) {
                Button("恢复全图") {
                    model.clearRAWCrop()
                    dismiss()
                }
                .disabled(model.rawCropSelection == nil)
                Spacer()
                Button("应用并重新冲印") {
                    do {
                        try model.setRAWCrop(
                            normalizedX:Double(rect.minX),
                            normalizedY:Double(rect.minY),
                            normalizedWidth:Double(rect.width),
                            normalizedHeight:Double(rect.height)
                        )
                        dismiss()
                    } catch {
                        self.error=error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy ||
                          model.simulationAwaitingCurrentSettings)
            }
            .padding(.horizontal,14).padding(.bottom,16)
        }
        .padding(.top,18)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
