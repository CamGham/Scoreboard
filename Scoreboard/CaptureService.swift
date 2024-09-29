//
//  CaptureService.swift
//  Scoreboard
//
//  Created by Cam Graham on 22/09/2024.
//

import AVFoundation
import CoreImage

// Run off of the MainActor
actor CaptureService {
    private let captureSession = AVCaptureSession()
    nonisolated let previewSource: PreviewSource
    
    private var activeVideoInput: AVCaptureDeviceInput?
    var videoOutput: AVCaptureVideoDataOutput?
    
    
    private let backCameraDiscoverSession: AVCaptureDevice.DiscoverySession
    
    init() {
        
        backCameraDiscoverSession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera, .builtInWideAngleCamera], mediaType: .video, position: .back)
        
        previewSource = DefaultPreviewSource(session: captureSession)
    
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
            
            
            // input
            guard let camera = cameras.first else { throw CameraError.videoDeviceUnavailable }
            
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(cameraInput) {
                captureSession.addInput(cameraInput)
            } else {
                throw CameraError.addInputFailed
            }
            activeVideoInput = cameraInput
            
            
            // output
            let liveOutput = AVCaptureVideoDataOutput()
            if captureSession.canAddOutput(liveOutput) {
//                captureSession.sessionPreset = .hd1280x720
                captureSession.addOutput(liveOutput)
            } else {
                throw CameraError.addOutputFailed
            }
            liveOutput.alwaysDiscardsLateVideoFrames = true
            
            videoOutput = liveOutput
            
            
//            outputDelegate = OutputDelegate()
            
            videoOutput?.setSampleBufferDelegate(self, queue: .global(qos: .userInitiated))

            captureSession.commitConfiguration()
            
            
            
        } catch {
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
