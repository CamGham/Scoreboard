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
    
    // Image size
    var bufferSize: CGSize = .zero
    let videoQueue = DispatchQueue(label: "VideoQueue", qos: .userInitiated, autoreleaseFrequency: .workItem)
    
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
            captureSession.sessionPreset = .vga640x480
            
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
            liveOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            // Set raw pixel output for detector
            liveOutput.setSampleBufferDelegate(captureDelegate, queue: videoQueue)
            videoOutput = liveOutput
            
            
            // image size for rects
            let captureConnection = liveOutput.connection(with: .video)
            captureConnection?.isEnabled = true
            do {
                try updateBufferDimensions()
            } catch {
                captureSession.commitConfiguration()
                
                print(error)
                throw CameraError.setupFailed
            }
            
            captureSession.commitConfiguration()
            
        } catch {
            throw CameraError.setupFailed
        }
    }
    
    func updateBufferDimensions() throws {
        guard let camera = cameras.first else { throw CameraError.videoDeviceUnavailable }
        
        do {
            try camera.lockForConfiguration()
            let dimensions = CMVideoFormatDescriptionGetDimensions((camera.activeFormat.formatDescription))
            bufferSize.width = CGFloat(dimensions.width)
            bufferSize.height = CGFloat(dimensions.height)
            camera.unlockForConfiguration()
        } catch {
            
            print(error)
            throw CameraError.setupFailed
        }
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
