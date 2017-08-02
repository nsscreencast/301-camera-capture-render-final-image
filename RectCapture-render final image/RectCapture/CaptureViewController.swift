//
//  ViewController.swift
//  RectCapture
//
//  Created by Ben Scheirman on 6/27/17.
//  Copyright © 2017 NSScreencast. All rights reserved.
//

import UIKit
import AVFoundation
import CoreImage

class CaptureViewController: UIViewController {
    
    let kCIPerspectiveCorrection = "CIPerspectiveCorrection"
    let kCIAffineTransform = "CIAffineTransform"
    
    let cameraShutterSoundID: SystemSoundID = 1108
    
    // MARK: - Properties
    
    var detectRectangles = true
    var wantsPhoto = false
    
    lazy var boxLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.backgroundColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.green.cgColor
        layer.lineWidth = 4
        layer.cornerRadius = 8
        layer.isOpaque = false
        layer.opacity = 0
        layer.frame = self.view.bounds
        self.view.layer.addSublayer(layer)
        return layer
    }()
    
    var hideBoxTimer: Timer?
    
    lazy var captureSession: AVCaptureSession = {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        return session
    }()
    
    var previewLayer: AVCaptureVideoPreviewLayer?
    
    let sampleBufferQueue = DispatchQueue.global(qos: .userInteractive)
    let imageProcessingQueue = DispatchQueue.global(qos: .userInitiated)
    
    let ciContext = CIContext()
    
    lazy var rectDetector: CIDetector = {
        return CIDetector(ofType: CIDetectorTypeRectangle,
                          context: self.ciContext,
                          options: [CIDetectorAccuracy : CIDetectorAccuracyHigh])!
    }()
    
    var flashLayer: CALayer?
    
    // MARK: - View Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        view.addGestureRecognizer(tap)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            setupCaptureSession()
        } else {
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { (authorized) in
                DispatchQueue.main.async {
                    if authorized {
                        self.setupCaptureSession()
                    }
                }
            })
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.bounds = view.frame
    }
    
    // MARK: - Actions
    
    @objc func onTap(_ tap: UITapGestureRecognizer) {
        // play shutter sound
        AudioServicesPlaySystemSound(cameraShutterSoundID)
        
        boxLayer.opacity = 0
        detectRectangles = false
        
        // flash
        flashScreen()
        
        // save photo
        wantsPhoto = true
    }
    
    private func flashScreen() {
        let flash = CALayer()
        flash.frame = view.bounds
        flash.backgroundColor = UIColor.white.cgColor
        view.layer.addSublayer(flash)
        flash.opacity = 0
        
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = 0.1
        anim.autoreverses = true
        anim.isRemovedOnCompletion = true
        anim.delegate = self
        flash.add(anim, forKey: "flashAnimation")
        
        self.flashLayer = flash
    }
    
    // MARK: - Rotation
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return [.portrait]
    }
    
    // MARK: - Camera Capture
    
    private func findCamera() -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInDualCamera,
            .builtInTelephotoCamera,
            .builtInWideAngleCamera
        ]
        
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
                                                         mediaType: .video,
                                                         position: .back)
        
        return discovery.devices.first
    }
    
    private func setupCaptureSession() {
        guard captureSession.inputs.isEmpty else { return }
        guard let camera = findCamera() else {
            print("No camera found")
            return
        }
        
        do {
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            captureSession.addInput(cameraInput)
            
            let preview = AVCaptureVideoPreviewLayer(session: captureSession)
            preview.frame = view.bounds
            preview.backgroundColor = UIColor.black.cgColor
            preview.videoGravity = .resizeAspect
            view.layer.addSublayer(preview)
            self.previewLayer = preview
            
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: sampleBufferQueue)
            
            captureSession.addOutput(output)
            
            captureSession.startRunning()
            
        } catch let e {
            print("Error creating capture session: \(e)")
            return
        }
    }
    
    private func displayRect(rect: CGRect) {
        /*
             -------------
             ---(layer)---
             ---(preview)-
             ---(rect)----
             ^
         */
        hideBoxTimer?.invalidate()
        boxLayer.frame = rect
        boxLayer.opacity = 1
        
        hideBoxTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { (timer) in
            self.boxLayer.opacity = 0
            timer.invalidate()
        })
    }
    
    private func displayQuad(points: (tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint)) {
        hideBoxTimer?.invalidate()
        let path = UIBezierPath()
        path.move(to: points.tl)
        path.addLine(to: points.tr)
        path.addLine(to: points.br)
        path.addLine(to: points.bl)
        path.addLine(to: points.tl)
        path.close()
        
        let cgPath = path.cgPath.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round,
                                      miterLimit: 0)
        boxLayer.path = cgPath
        boxLayer.opacity = 1
        
        hideBoxTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { (timer) in
            self.boxLayer.opacity = 0
            timer.invalidate()
        })
    }
    
    private func perspectiveCorrect(_ image: CIImage, rectFeature: CIRectangleFeature) -> CIImage? {
        
        let perspectiveFilter = CIFilter(name: kCIPerspectiveCorrection)!
        perspectiveFilter.setValue(image, forKey: kCIInputImageKey)
        
        let corners = [
            (rectFeature.topLeft, "inputTopLeft"),
            (rectFeature.topRight, "inputTopRight"),
            (rectFeature.bottomRight, "inputBottomRight"),
            (rectFeature.bottomLeft, "inputBottomLeft"),
        ]
        
        for (point, key) in corners {
            let vector = CIVector(cgPoint: point)
            perspectiveFilter.setValue(vector, forKey: key)
        }
        
        guard let correctedImage = perspectiveFilter.outputImage else { return nil }
        let extent = correctedImage.extent
        
        let transformFilter = CIFilter(name: kCIAffineTransform)!
        /*----*
         |    |
         *----*/
        
        var transform = CGAffineTransform(translationX: extent.midX, y: -extent.midY)
        transform = transform.rotated(by: -.pi/2)
        transform = transform.translatedBy(x: -extent.midX, y: extent.midY)
        transformFilter.setValue(correctedImage, forKey: kCIInputImageKey)
        transformFilter.setValue(transform, forKey: kCIInputTransformKey)
        
        return transformFilter.outputImage
    }
    
    private func displayImage(ciImage: CIImage) {
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            fatalError()
        }
        
        let image = UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
        let imageView = UIImageView(image: image)
        imageView.frame = view.bounds
        imageView.backgroundColor = UIColor(white: 0, alpha: 0.8)
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = 0
        view.addSubview(imageView)
        
        UIView.animate(withDuration: 0.3) {
            imageView.alpha = 1
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            UIView.animate(withDuration: 0.3, animations: {
                imageView.alpha = 0
            }, completion: { completed in
                imageView.removeFromSuperview()
                self.detectRectangles = true
            })
        }
        
    }
}

extension CaptureViewController : AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        guard wantsPhoto || detectRectangles else { return }
        
        let image = CIImage(cvImageBuffer: imageBuffer)
        for feature in rectDetector.features(in: image, options: nil) {
            guard let rectFeature = feature as? CIRectangleFeature else { continue }
            
            let imageWidth = image.extent.height
            let imageHeight = image.extent.width
            
            DispatchQueue.main.sync {
                let imageScale = min(view.frame.size.width / imageWidth,
                                     view.frame.size.height / imageHeight)
//                let origin = CGPoint(x: rectFeature.topLeft.y * imageScale - rectFeature.bounds.size.height * imageScale,
//                                     y: rectFeature.topLeft.x * imageScale)
//                let size = CGSize(width: rectFeature.bounds.size.height * imageScale,
//                                  height: rectFeature.bounds.size.width * imageScale)
//
//                let rect = CGRect(origin: origin, size: size)
//                self.displayRect(rect: rect)
                
                let bl = CGPoint(x: rectFeature.topLeft.y * imageScale,
                                 y: rectFeature.topLeft.x * imageScale)
                let tl = CGPoint(x: rectFeature.topRight.y * imageScale,
                                 y: rectFeature.topRight.x * imageScale)
                let tr = CGPoint(x: rectFeature.bottomRight.y * imageScale,
                                 y: rectFeature.bottomRight.x * imageScale)
                let br = CGPoint(x: rectFeature.bottomLeft.y * imageScale,
                                 y: rectFeature.bottomLeft.x * imageScale)
                self.displayQuad(points: (tl: tl, tr: tr, br: br, bl: bl) )
                
                if wantsPhoto {
                    wantsPhoto = false
                    imageProcessingQueue.async {
                        if let processedImage = self.perspectiveCorrect(image, rectFeature: rectFeature) {
                            DispatchQueue.main.async {
                                self.displayImage(ciImage: processedImage)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension CaptureViewController : CAAnimationDelegate {
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        flashLayer?.removeFromSuperlayer()
        flashLayer = nil
    }
}
