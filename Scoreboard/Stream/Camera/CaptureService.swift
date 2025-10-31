//
//  CaptureService.swift
//  Scoreboard
//
//  Created by Cam Graham on 22/09/2024.
//

import AVFoundation
import CoreImage
import UIKit

// Run off of the MainActor
actor CaptureService {
    private let captureSession = AVCaptureSession()
    nonisolated let previewSource: PreviewSource
    
    private var activeVideoInput: AVCaptureDeviceInput?
    var videoOutput: AVCaptureVideoDataOutput?
    var captureDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    
    private let backCameraDiscoverSession: AVCaptureDevice.DiscoverySession
    
    let videoQueue = DispatchQueue(label: "VideoQueue", qos: .userInitiated, autoreleaseFrequency: .workItem)
    
    
    // rotation
    // An object that monitors video device rotations.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator!
    private var rotationObservers = [AnyObject]()
    
    init() {
        
        backCameraDiscoverSession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera, .builtInWideAngleCamera], mediaType: .video, position: .back)
        
        previewSource = DefaultPreviewSource(session: captureSession)
    }
    
    func setOutputDelegate(source: AVCaptureVideoDataOutputSampleBufferDelegate) {
        captureDelegate = source
    }
    
    var isAuthorized: Bool {
        get async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            // Determine whether a person previously authorized camera access.
            var isAuthorized = status == .authorized
            // If the system hasn't determined their authorization status,
            // explicitly prompt them for approval.
            if status == .notDetermined {
                isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            return isAuthorized
        }
    }
    
    
    
    var cameras: [AVCaptureDevice] {
        var cams: [AVCaptureDevice] = []
        if let backCam = backCameraDiscoverSession.devices.first {
            cams.append(backCam)
        }
        return cams
    }
    
    func start() async throws {
        guard await isAuthorized, !captureSession.isRunning else {
            return
        }
        
        try setup()
        captureSession.startRunning()
    }
    
    func setup() throws {
        do {
            captureSession.beginConfiguration()
            // YOLOv3 only requires 480
//            captureSession.sessionPreset = .vga640x480
            captureSession.sessionPreset = .high
            
            // input
            guard let camera = cameras.first else { throw CameraError.videoDeviceUnavailable }
            
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(cameraInput) {
                captureSession.addInput(cameraInput)
            } else {
                captureSession.commitConfiguration()
                throw CameraError.addInputFailed
            }
            activeVideoInput = cameraInput
            
            
            // output
            let liveOutput = AVCaptureVideoDataOutput()
            if captureSession.canAddOutput(liveOutput) {
                captureSession.addOutput(liveOutput)
            } else {
                captureSession.commitConfiguration()
                throw CameraError.addOutputFailed
            }
            liveOutput.alwaysDiscardsLateVideoFrames = true
            
            // pixel buffer for ML observation
            guard let captureDelegate = captureDelegate else {
                captureSession.commitConfiguration()
                throw CameraError.setupFailed
            }
            
//            liveOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)]
            // 10 bit
//            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            
            //low
//            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            
            
            // Set raw pixel output for detector
            liveOutput.setSampleBufferDelegate(captureDelegate, queue: videoQueue)
            videoOutput = liveOutput
            
            // Configure a rotation coordinator for the default video device.
            createRotationCoordinator(for: camera)
            
            // image size for rects
            let captureConnection = liveOutput.connection(with: .video)
            captureConnection?.isEnabled = true
            
            captureSession.commitConfiguration()
            
        } catch {
            throw CameraError.setupFailed
        }
    }
    
    
    private func createRotationCoordinator(for device: AVCaptureDevice) {
        // Create a new rotation coordinator for this device.
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: videoPreviewLayer)
        
        // Set initial rotation state on the preview and output connections.
        updatePreviewRotation(rotationCoordinator.videoRotationAngleForHorizonLevelPreview)
        updateCaptureRotation(rotationCoordinator.videoRotationAngleForHorizonLevelCapture)
        
        // Cancel previous observations.
        rotationObservers.removeAll()
        
        // Add observers to monitor future changes.
        rotationObservers.append(
            rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                // Update the capture preview rotation.
                Task { await self.updatePreviewRotation(angle) }
            }
        )
        
        rotationObservers.append(
            rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                // Update the capture preview rotation.
                Task { await self.updateCaptureRotation(angle) }
            }
        )
    }
    
    private func updatePreviewRotation(_ angle: CGFloat) {
        let previewLayer = videoPreviewLayer
        Task { @MainActor in
            // Set initial rotation angle on the video preview.
            previewLayer.connection?.videoRotationAngle = angle
        }
    }
    
    private func updateCaptureRotation(_ angle: CGFloat) {
        // Update the orientation for all output services.
        
//        outputServices.forEach { $0.setVideoRotationAngle(angle) }
    }
    
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // Access the capture session's connected preview layer.
        guard let previewLayer = captureSession.connections.compactMap({ $0.videoPreviewLayer }).first else {
            fatalError("The app is misconfigured. The capture session should have a connection to a preview layer.")
        }
        return previewLayer
    }
    
    func stop() {
        captureSession.stopRunning()
    }
}

enum CameraError: Error {
    case videoDeviceUnavailable
    case audioDeviceUnavailable
    case addInputFailed
    case addOutputFailed
    case setupFailed
    case deviceChangeFailed
}
