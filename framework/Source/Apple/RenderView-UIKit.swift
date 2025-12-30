#if canImport(UIKit)

import UIKit

// TODO: Add support for transparency
// TODO: Deal with view resizing
public class RenderView:UIView, ImageConsumer {
    public var backgroundRenderColor = Color.black
    public var fillMode = FillMode.preserveAspectRatio
    public var orientation:ImageOrientation = .portrait
    public var sizeInPixels:Size { get { return Size(width:Float(frame.size.width * contentScaleFactor), height:Float(frame.size.height * contentScaleFactor))}}
    
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    var displayFramebuffer:GLuint?
    var displayRenderbuffer:GLuint?
    var backingSize = GLSize(width:0, height:0)
    private var storedFramebuffer:Framebuffer?
    
    private lazy var displayShader:ShaderProgram = {
        return sharedImageProcessingContext.passthroughShader
    }()

    // TODO: Need to set viewport to appropriate size, resize viewport on view reshape
    
    required public init?(coder:NSCoder) {
        super.init(coder:coder)
        self.commonInit()
    }

    public override init(frame:CGRect) {
        super.init(frame:frame)
        self.commonInit()
    }

    override public class var layerClass:Swift.AnyClass {
        get {
            return CAEAGLLayer.self
        }
    }
    
    func commonInit() {
        self.contentScaleFactor = UIScreen.main.scale
        
        let eaglLayer = self.layer as! CAEAGLLayer
        eaglLayer.isOpaque = true
        eaglLayer.drawableProperties = [String(describing: NSNumber(value:false)): kEAGLDrawablePropertyRetainedBacking, kEAGLColorFormatRGBA8: kEAGLDrawablePropertyColorFormat]
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        // If the view resized, recreate the display framebuffer on next render.
        let desiredSize = self.sizeInPixels
        if (displayFramebuffer != nil) &&
            ((backingSize.width != desiredSize.glWidth()) || (backingSize.height != desiredSize.glHeight())) {
            destroyDisplayFramebuffer()
        }
        
        // For still images, we may have dropped the only frame if the view was zero-sized.
        // Once we have a valid size, render the last stored frame.
        renderStoredFramebufferIfPossible()
    }
    
    deinit {
        storedFramebuffer?.unlock()
        storedFramebuffer = nil
        destroyDisplayFramebuffer()
    }
    
    // MARK: - Snapshotting
    //
    // NOTE: UIKit screenshot methods like `drawHierarchy(in:afterScreenUpdates:)` will not
    // capture OpenGL ES (CAEAGLLayer) content, often resulting in a blank image.
    // Use this to capture the current displayed pixels instead.
    public func captureCurrentImage(completion: @escaping (UIImage?) -> Void) {
        sharedImageProcessingContext.runOperationAsynchronously { [weak self] in
            guard let self else { return }
            
            // Ensure we have a drawable backing store.
            if (self.displayFramebuffer == nil) {
                guard self.createDisplayFramebuffer() else {
                    runAsynchronouslyOnMainQueue { completion(nil) }
                    return
                }
            }
            
            let width = Int(self.backingSize.width)
            let height = Int(self.backingSize.height)
            guard width > 0, height > 0 else {
                runAsynchronouslyOnMainQueue { completion(nil) }
                return
            }
            
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), self.displayFramebuffer!)
            glViewport(0, 0, self.backingSize.width, self.backingSize.height)
            glFinish()
            
            let bytesPerPixel = 4
            let bytesPerRow = width * bytesPerPixel
            let byteCount = bytesPerRow * height
            
            let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
            glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), raw)
            
            // Flip vertically (OpenGL origin is bottom-left; UIKit expects top-left).
            let flipped = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
            for y in 0..<height {
                let src = raw.advanced(by: (height - 1 - y) * bytesPerRow)
                let dst = flipped.advanced(by: y * bytesPerRow)
                dst.assign(from: src, count: bytesPerRow)
            }
            raw.deallocate()
            
            guard let provider = CGDataProvider(
                dataInfo: nil,
                data: flipped,
                size: byteCount,
                releaseData: renderViewDataProviderReleaseCallback
            ) else {
                flipped.deallocate()
                runAsynchronouslyOnMainQueue { completion(nil) }
                return
            }
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ) else {
                runAsynchronouslyOnMainQueue { completion(nil) }
                return
            }
            
            let image = UIImage(cgImage: cgImage, scale: self.contentScaleFactor, orientation: .up)
            runAsynchronouslyOnMainQueue { completion(image) }
        }
    }
    
    @discardableResult
    func createDisplayFramebuffer() -> Bool {
        var newDisplayFramebuffer:GLuint = 0
        glGenFramebuffers(1, &newDisplayFramebuffer)
        displayFramebuffer = newDisplayFramebuffer
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), displayFramebuffer!)

        var newDisplayRenderbuffer:GLuint = 0
        glGenRenderbuffers(1, &newDisplayRenderbuffer)
        displayRenderbuffer = newDisplayRenderbuffer
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), displayRenderbuffer!)

        sharedImageProcessingContext.context.renderbufferStorage(Int(GL_RENDERBUFFER), from:self.layer as! CAEAGLLayer)

        var backingWidth:GLint = 0
        var backingHeight:GLint = 0
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &backingHeight)
        backingSize = GLSize(width:backingWidth, height:backingHeight)
        
        guard ((backingWidth > 0) && (backingHeight > 0)) else {
            // This can happen if the view hasn't been laid out yet (size is still zero),
            // or if the backing store allocation failed. Don't crash the entire pipeline:
            // drop the current frame and try again on the next one.
            debugPrint("RenderView backing store had a zero size (w:\(backingWidth), h:\(backingHeight)). Dropping frame.")
            destroyDisplayFramebuffer()
            return false
        }

        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if (status != GLenum(GL_FRAMEBUFFER_COMPLETE)) {
            debugPrint("Display framebuffer creation failed with error: \(FramebufferCreationError(errorCode:status)). Dropping frame.")
            destroyDisplayFramebuffer()
            return false
        }
        
        return true
    }
    
    func destroyDisplayFramebuffer() {
        sharedImageProcessingContext.runOperationSynchronously{
            if let displayFramebuffer = self.displayFramebuffer {
                var temporaryFramebuffer = displayFramebuffer
                glDeleteFramebuffers(1, &temporaryFramebuffer)
                self.displayFramebuffer = nil
            }
            
            if let displayRenderbuffer = self.displayRenderbuffer {
                var temporaryRenderbuffer = displayRenderbuffer
                glDeleteRenderbuffers(1, &temporaryRenderbuffer)
                self.displayRenderbuffer = nil
            }
        }
    }
    
    func activateDisplayFramebuffer() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), displayFramebuffer!)
        glViewport(0, 0, backingSize.width, backingSize.height)
    }
    
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        if (displayFramebuffer == nil) {
            guard self.createDisplayFramebuffer() else {
                storeForRedraw(framebuffer)
                return
            }
        }
        self.activateDisplayFramebuffer()
        
        clearFramebufferWithColor(backgroundRenderColor)

        let scaledVertices = fillMode.transformVertices(verticallyInvertedImageVertices, fromInputSize:framebuffer.sizeForTargetOrientation(self.orientation), toFitSize:backingSize)
        renderQuadWithShader(self.displayShader, vertices:scaledVertices, inputTextures:[framebuffer.texturePropertiesForTargetOrientation(self.orientation)])
        framebuffer.unlock()
        
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        sharedImageProcessingContext.presentBufferForDisplay()
    }
    
    private func storeForRedraw(_ framebuffer:Framebuffer) {
        // Keep only the latest framebuffer around; release any previously stored one.
        storedFramebuffer?.unlock()
        storedFramebuffer = framebuffer
        
        // Trigger a layout pass so that once the view has a non-zero size, we can render it.
        runAsynchronouslyOnMainQueue { [weak self] in
            self?.setNeedsLayout()
        }
    }
    
    private func renderStoredFramebufferIfPossible() {
        // Only attempt if we have something to draw and the view is attached.
        guard window != nil else { return }
        guard storedFramebuffer != nil else { return }
        
        sharedImageProcessingContext.runOperationAsynchronously { [weak self] in
            guard let self else { return }
            guard let framebuffer = self.storedFramebuffer else { return }
            
            if (self.displayFramebuffer == nil) {
                guard self.createDisplayFramebuffer() else {
                    // Keep stored framebuffer for a future attempt.
                    return
                }
            }
            
            self.activateDisplayFramebuffer()
            clearFramebufferWithColor(self.backgroundRenderColor)
            
            let scaledVertices = self.fillMode.transformVertices(
                verticallyInvertedImageVertices,
                fromInputSize: framebuffer.sizeForTargetOrientation(self.orientation),
                toFitSize: self.backingSize
            )
            renderQuadWithShader(self.displayShader, vertices:scaledVertices, inputTextures:[framebuffer.texturePropertiesForTargetOrientation(self.orientation)])
            
            framebuffer.unlock()
            self.storedFramebuffer = nil
            
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), self.displayRenderbuffer!)
            sharedImageProcessingContext.presentBufferForDisplay()
        }
    }
}

// Why are these flipped in the callback definition?
private func renderViewDataProviderReleaseCallback(_ context: UnsafeMutableRawPointer?, data: UnsafeRawPointer, size: Int) {
    data.deallocate()
}
#endif
