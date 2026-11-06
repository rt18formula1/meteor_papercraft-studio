import AppKit
import CoreVideo
import ImageIO
import Vision

struct ForegroundMatte {
    let width: Int
    let height: Int
    let alpha: [UInt8]
    let cutout: CGImage?
    let averageColor:CGColor
    let confidence: Double
}

enum TransparencyProcessor {
    @available(macOS 14.0, *)
    private static func visionForegroundMask(from image:CGImage,width:Int,height:Int)throws->[UInt8]? {
        let handler=VNImageRequestHandler(cgImage:image,options:[:])
        let request=VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation=request.results?.first else{return nil}
        let buffer=try observation.generateScaledMaskForImage(forInstances:observation.allInstances,from:handler)
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(buffer) else{return nil}
        let sourceWidth=CVPixelBufferGetWidth(buffer),sourceHeight=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRow(buffer)
        let source=base.assumingMemoryBound(to:UInt8.self)
        var result=[UInt8](repeating:0,count:width*height)
        for y in 0..<height {
            let sy=min(sourceHeight-1,Int((Double(y)+0.5)*Double(sourceHeight)/Double(height)))
            for x in 0..<width {
                let sx=min(sourceWidth-1,Int((Double(x)+0.5)*Double(sourceWidth)/Double(width)))
                result[y*width+x]=source[sy*stride+sx]
            }
        }
        return result
    }

    static func makeMatte(from image:CGImage,tolerance:Double,maxDimension:Int=640,createCutout:Bool=true) throws -> ForegroundMatte {
        let scale=min(1.0,Double(maxDimension)/Double(max(image.width,image.height)))
        let width=max(2,Int(Double(image.width)*scale)),height=max(2,Int(Double(image.height)*scale))
        let row=width*4
        var bytes=[UInt8](repeating:0,count:row*height)
        let info=CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let color=CGColorSpaceCreateDeviceRGB()
        let rendered=bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:row,space:color,bitmapInfo:info) else { return false }
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard rendered else { throw SilhouetteError.cannotReadPixels }
        func colorAt(_ i:Int)->(Double,Double,Double) { (Double(bytes[i])/255,Double(bytes[i+1])/255,Double(bytes[i+2])/255) }
        var border:[(Double,Double,Double)]=[]
        let strideBy=max(1,max(width,height)/200)
        for x in Swift.stride(from:0,to:width,by:strideBy) { border.append(colorAt((x)*4));border.append(colorAt(((height-1)*width+x)*4)) }
        for y in Swift.stride(from:0,to:height,by:strideBy) { border.append(colorAt((y*width)*4));border.append(colorAt((y*width+width-1)*4)) }
        func median(_ values:[Double])->Double { let v=values.sorted();return v[v.count/2] }
        let background=(median(border.map{$0.0}),median(border.map{$0.1}),median(border.map{$0.2}))
        let borderDistances=border.map { c in sqrt(pow(c.0-background.0,2)+pow(c.1-background.1,2)+pow(c.2-background.2,2))/sqrt(3) }
        let borderMedian=median(borderDistances)
        let borderSpread=median(borderDistances.map { abs($0-borderMedian) })
        let backgroundConsistency=max(0.0,min(1.0,1.0-borderSpread/0.12))
        let threshold=max(0.035,tolerance)
        var usedVision=false
        var candidate=[UInt8](repeating:0,count:width*height)
        if #available(macOS 14.0, *), let visionMask=try? visionForegroundMask(from:image,width:width,height:height) {
            candidate=visionMask.map{$0 >= 96 ? UInt8(1):UInt8(0)};usedVision=true
        } else {
            for i in 0..<(width*height) {
                let c=colorAt(i*4),d=sqrt(pow(c.0-background.0,2)+pow(c.1-background.1,2)+pow(c.2-background.2,2))/sqrt(3)
                candidate[i] = d > threshold ? 1:0
            }
        }
        var seen=[UInt8](repeating:0,count:candidate.count),components:[[Int]]=[]
        for i in candidate.indices where candidate[i] != 0 && seen[i] == 0 {
            var queue=[i],head=0;seen[i]=1
            while head<queue.count {
                let p=queue[head];head += 1;let x=p%width,y=p/width
                let ns=[x>0 ? p-1 : -1,x+1<width ? p+1 : -1,y>0 ? p-width : -1,y+1<height ? p+width : -1]
                for n in ns where n>=0 && candidate[n] != 0 && seen[n] == 0 { seen[n]=1;queue.append(n) }
            }
            if queue.count>max(20,width*height/20000) { components.append(queue) }
        }
        guard !components.isEmpty else { throw SilhouetteError.cannotReadPixels }
        let imageCenter=(Double(width-1)/2,Double(height-1)/2)
        func componentScore(_ component:[Int])->Double {
            let strideBy=max(1,component.count/4000)
            var sumX=0.0,sumY=0.0,count=0.0
            for (index,pixel) in component.enumerated() where index % strideBy == 0 {
                sumX += Double(pixel % width);sumY += Double(pixel / width);count += 1
            }
            let cx=sumX/max(1,count),cy=sumY/max(1,count)
            let dx=(cx-imageCenter.0)/Double(width),dy=(cy-imageCenter.1)/Double(height)
            let centerAffinity=exp(-((dx*dx+dy*dy)/0.045))
            return log(Double(component.count)+1)*(0.35+0.65*centerAffinity)
        }
        // A keyboard edge, stand, or reflection can form a larger thresholded
        // component than the subject. Prefer a substantial central component
        // while retaining area as a tie-breaker for off-center subjects.
        let foreground=components.max { componentScore($0) < componentScore($1) }!
        var mask=[UInt8](repeating:0,count:width*height)
        for i in foreground { mask[i]=1 }

        // Fill enclosed holes while leaving any background connected to the image border transparent.
        var outside=[UInt8](repeating:0,count:mask.count),queue:[Int]=[]
        for x in 0..<width { for i in [x,(height-1)*width+x] where mask[i]==0 && outside[i]==0 { outside[i]=1;queue.append(i) } }
        for y in 0..<height { for i in [y*width,y*width+width-1] where mask[i]==0 && outside[i]==0 { outside[i]=1;queue.append(i) } }
        var head=0
        while head<queue.count {
            let p=queue[head];head += 1;let x=p%width,y=p/width
            for n in [x>0 ? p-1 : -1,x+1<width ? p+1 : -1,y>0 ? p-width : -1,y+1<height ? p+width : -1] where n>=0 && mask[n]==0 && outside[n]==0 { outside[n]=1;queue.append(n) }
        }
        for i in mask.indices where outside[i]==0 { mask[i]=1 }
        var alpha=mask.map{$0 == 0 ? UInt8(0):UInt8(255)}
        // Antialias the boundary with a one-pixel half-opacity fringe for clean printed cutouts.
        for y in 1..<(height-1) { for x in 1..<(width-1) {
            let i=y*width+x
            if mask[i] != 0 && (mask[i-1]==0 || mask[i+1]==0 || mask[i-width]==0 || mask[i+width]==0) { alpha[i]=192 }
        }}
        var sums=(r:0.0,g:0.0,b:0.0,n:0.0)
        for i in mask.indices where mask[i] != 0 { sums.r += Double(bytes[i*4])/255;sums.g += Double(bytes[i*4+1])/255;sums.b += Double(bytes[i*4+2])/255;sums.n += 1 }
        let average=CGColor(colorSpace:color,components:[sums.r/max(1,sums.n),sums.g/max(1,sums.n),sums.b/max(1,sums.n),1]) ?? NSColor.lightGray.cgColor
        let foregroundRatio=sums.n/Double(width*height)
        let areaConfidence=(foregroundRatio > 0.01 && foregroundRatio < 0.92) ? 1.0 : 0.45
        let confidence=usedVision ? 0.9 : 0.7*backgroundConsistency+0.3*areaConfidence
        let cutout=createCutout ? try renderCutout(image:image,mask:alpha,maskWidth:width,maskHeight:height) : nil
        return ForegroundMatte(width:width,height:height,alpha:alpha,cutout:cutout,averageColor:average,confidence:confidence)
    }

    static func clipped(_ matte:ForegroundMatte,to polygon:[Point2],original:CGImage,createCutout:Bool)throws->ForegroundMatte {
        guard polygon.count>=3 else{return matte}
        var alpha=matte.alpha
        for y in 0..<matte.height { for x in 0..<matte.width {
            let px=(Double(x)+0.5)/Double(matte.width),py=(Double(y)+0.5)/Double(matte.height)
            var inside=false,j=polygon.count-1
            for i in polygon.indices {
                let a=polygon[i],b=polygon[j]
                if (a.y>py) != (b.y>py),px < (b.x-a.x)*(py-a.y)/(b.y-a.y)+a.x { inside.toggle() }
                j=i
            }
            alpha[y*matte.width+x] = inside ? 255 : 0
        }}
        let cutout=createCutout ? try renderCutout(image:original,mask:alpha,maskWidth:matte.width,maskHeight:matte.height) : nil
        return ForegroundMatte(width:matte.width,height:matte.height,alpha:alpha,cutout:cutout,averageColor:matte.averageColor,confidence:matte.confidence)
    }

    private static func renderCutout(image:CGImage,mask:[UInt8],maskWidth:Int,maskHeight:Int)throws->CGImage {
        let width=image.width,height=image.height,row=width*4
        var pixels=[UInt8](repeating:0,count:row*height)
        let info=CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let color=CGColorSpaceCreateDeviceRGB()
        let rendered=pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:row,space:color,bitmapInfo:info) else { return false }
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard rendered else { throw SilhouetteError.cannotReadPixels }
        for y in 0..<height {
            let sy=(Double(y)+0.5)*Double(maskHeight)/Double(height)-0.5,y0=max(0,min(maskHeight-1,Int(floor(sy)))),y1=min(maskHeight-1,y0+1),fy=max(0,min(1,sy-Double(y0)))
            for x in 0..<width {
                let sx=(Double(x)+0.5)*Double(maskWidth)/Double(width)-0.5,x0=max(0,min(maskWidth-1,Int(floor(sx)))),x1=min(maskWidth-1,x0+1),fx=max(0,min(1,sx-Double(x0)))
                let a=Double(mask[y0*maskWidth+x0])*(1-fx)*(1-fy)+Double(mask[y0*maskWidth+x1])*fx*(1-fy)+Double(mask[y1*maskWidth+x0])*(1-fx)*fy+Double(mask[y1*maskWidth+x1])*fx*fy
                let offset=(y*width+x)*4,old=Double(pixels[offset+3]),target=a
                if old>0 { for c in 0..<3 { pixels[offset+c]=UInt8(max(0,min(255,(Double(pixels[offset+c])*target/old).rounded()))) } }
                pixels[offset+3]=UInt8(max(0,min(255,target.rounded())))
            }
        }
        let data=Data(pixels) as CFData
        guard let provider=CGDataProvider(data:data),let result=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:row,space:color,bitmapInfo:CGBitmapInfo(rawValue:info),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw SilhouetteError.cannotReadPixels }
        return result
    }

    static func makeImageBuffer(from image:CGImage)->CVPixelBuffer? {
        var buffer:CVPixelBuffer?
        let attributes=[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault,image.width,image.height,kCVPixelFormatType_32BGRA,attributes,&buffer)==kCVReturnSuccess,let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer,[]);defer{CVPixelBufferUnlockBaseAddress(buffer,[])}
        guard let base=CVPixelBufferGetBaseAddress(buffer),let context=CGContext(data:base,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return buffer
    }

    static func makeMaskBuffer(_ matte:ForegroundMatte,width:Int,height:Int)->CVPixelBuffer? {
        var buffer:CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_OneComponent8,nil,&buffer)==kCVReturnSuccess,let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer,[]);defer{CVPixelBufferUnlockBaseAddress(buffer,[])}
        guard let base=CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride=CVPixelBufferGetBytesPerRow(buffer)
        let pixels=base.assumingMemoryBound(to:UInt8.self)
        for y in 0..<height {
            let sy=max(0,min(matte.height-1,Int((Double(y)+0.5)*Double(matte.height)/Double(height))))
            for x in 0..<width {
                let sx=max(0,min(matte.width-1,Int((Double(x)+0.5)*Double(matte.width)/Double(width))))
                pixels[y*stride+x]=matte.alpha[sy*matte.width+sx]
            }
        }
        return buffer
    }
}
