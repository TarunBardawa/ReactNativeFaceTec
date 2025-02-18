import AVFoundation

// implementing SessionDelegate which is the same than FaceTecFaceScanProcessorDelegate
// but causes no issues during build
class EnrollmentProcessor: NSObject, URLSessionTaskDelegate, SessionDelegate {
    var maxRetries: Int?
    var enrollmentIdentifier: String!
    private let defaultMaxRetries = -1

    var isSuccess = false
    var lastMessage: String!
    var lastResult: FaceTecSessionResult!
    var resultCallback: FaceTecFaceScanResultCallback!
    var retryAttempt = 0
    var timeout: TimeInterval? = nil

    var processingDelegate: ProcessingDelegate
    var presentSessionVCFrom: UIViewController
    var sessionDelegate: SessionProcessingDelegate?

    private var alwaysRetry: Bool {
        get {
            return maxRetries == nil || maxRetries! < 0
        }
    }

    init(fromVC: UIViewController, delegate: ProcessingDelegate) {
        self.processingDelegate = delegate
        self.presentSessionVCFrom = fromVC
      
        super.init()
        // instantiating a session delegate ObjectiveC class
        // wrapping the enrollment processor
        self.sessionDelegate = SessionProcessingDelegate(session: self)
    }

    func enroll(_ enrollmentIdentifier: String, _ maxRetries: Int? = nil, _ timeout: Int? = nil) {
        requestCameraPermissions() {
            self.startSession() { sessionToken in
                self.enrollmentIdentifier = enrollmentIdentifier
                self.maxRetries = self.defaultMaxRetries

                // there're issues with passing nil / null for numbers
                // we're passing -1 if no param was set on JS side
                // so here we have to add additional > (or >=) 0 check
                if maxRetries != nil && maxRetries! >= 0 {
                    self.maxRetries = maxRetries!
                }

                if timeout != nil && timeout! > 0 {
                  self.timeout = Double(timeout!) / 1000
                }

                DispatchQueue.main.async {
                    // the sessionDelegate now passes to createSessionVC instead of EnrollmentProcessor
                    let sessionVC = FaceTec.sdk.createSessionVC(faceScanProcessorDelegate: self.sessionDelegate!, sessionToken: sessionToken)

                    self.presentSessionVCFrom.present(sessionVC, animated: true, completion: {
                        EventEmitter.shared.dispatch(.UI_READY)
                    })
                }
            }
        }
    }

    func onFaceTecSessionResult(sessionResult: FaceTecSessionResult, faceScanResultCallback: FaceTecFaceScanResultCallback) {
        lastResult = sessionResult
        resultCallback = faceScanResultCallback

        if sessionResult.status != .sessionCompletedSuccessfully {
            FaceVerification.shared.cancelInFlightRequests()
            faceScanResultCallback.onFaceScanResultCancel()
            return
        }


        // notifying that capturing is done
        EventEmitter.shared.dispatch(.CAPTURE_DONE)

        // perform verification
        sendEnrollmentRequest()
    }

    func onFaceTecSessionDone() {
        processingDelegate.onProcessingComplete(isSuccess: isSuccess, sessionResult: lastResult, sessionMessage: lastMessage)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        // get progress while performing the upload
        let uploaded: Float = Float(totalBytesSent) / Float(totalBytesExpectedToSend)

        // updating the UX, upload progress from 10 to 80%
        resultCallback.onFaceScanUploadProgress(uploadedPercent: 0.1 + 0.7 * uploaded)

        if (totalBytesSent == totalBytesExpectedToSend) {
            let processingMessage = NSMutableAttributedString.init(string: Customization.resultFacescanProcessingMessage)

            // switch status message to processing once upload completed
            resultCallback.onFaceScanUploadMessageOverride(uploadMessageOverride: processingMessage)
        }
    }

    private func startSession(sessionTokenCallback: @escaping (String) -> Void) {
        FaceVerification.shared.getSessionToken() { sessionToken, error in
            if error != nil {
                self.processingDelegate.onSessionTokenError()
                return
            }

            sessionTokenCallback(sessionToken!)
        }
    }

    private func requestCameraPermissions(requestCallback: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestCallback()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { (granted) in
                if (granted) {
                    requestCallback()
                } else {
                    self.processingDelegate.onCameraAccessError()
                }
            }
        case .denied,
             .restricted:
            processingDelegate.onCameraAccessError()
        @unknown default:
            processingDelegate.onCameraAccessError()
        }
    }

    private func sendEnrollmentRequest() -> Void {
        // setting initial progress to 0 for freeze progress bar
        resultCallback.onFaceScanUploadProgress(uploadedPercent: 0)

        let payload: [String : Any] = [
            "faceScan": lastResult.faceScanBase64!,
            "auditTrailImage": lastResult.auditTrailCompressedBase64!.first!,
            "lowQualityAuditTrailImage": lastResult.lowQualityAuditTrailCompressedBase64!.first!,
            "sessionId": lastResult.sessionId
        ]

        FaceVerification.shared.enroll(
            enrollmentIdentifier!,
            payload,
            withTimeout: timeout,
            withDelegate: self
        ) { response, error in
            self.resultCallback.onFaceScanUploadProgress(uploadedPercent: 1)

            if error != nil {
                self.handleEnrollmentError(error!, response)
                return
            }

            self.isSuccess = true
            self.lastMessage = Customization.resultSuccessMessage

            FaceTecCustomization.setOverrideResultScreenSuccessMessage(self.lastMessage)
            self.resultCallback.onFaceScanResultSucceed()
        }
    }

    private func handleEnrollmentError(_ error: Error, _ response: [String: AnyObject]?) -> Void {
        let faceTecError = (error as? FaceVerificationError) ?? .unexpectedResponse

        // by default we'll use exception's message as lastMessage
        lastMessage = faceTecError.message

        if response != nil {
            let enrollmentResult = response?["enrollmentResult"] as? [String: Bool]

            // if isDuplicate is strictly true, that means we have dup face
            let isDuplicateIssue = true == enrollmentResult?["isDuplicate"]
            let is3DMatchIssue = true == enrollmentResult?["isNotMatch"]
            let isLivenessIssue = false == enrollmentResult?["isLive"]
            let isEnrolled = true == enrollmentResult?["isEnrolled"]

            // if there's no duplicate / 3d match issues but we have
            // liveness issue strictly - we'll check for possible session retry
            if !isDuplicateIssue && !is3DMatchIssue && isLivenessIssue {
                // if haven't reached retries threshold or max retries is disabled
                // (is null or < 0) we'll ask to retry capturing
                if alwaysRetry || retryAttempt < maxRetries! {
                    let retryMessage = NSMutableAttributedString.init(string: lastMessage)

                    // increasing retry attempts counter
                    retryAttempt += 1
                    // showing reason
                    resultCallback.onFaceScanUploadMessageOverride(uploadMessageOverride: retryMessage)
                    // notifying about retry
                    resultCallback.onFaceScanResultRetry()

                    // dispatching retry event
                    EventEmitter.shared.dispatch(.FV_RETRY, [
                        "reason": lastMessage!,
                        "match3d": !is3DMatchIssue,
                        "liveness": !isLivenessIssue,
                        "duplicate": isDuplicateIssue,
                        "enrolled": isEnrolled
                    ])

                    return
                }
            }
        }

        resultCallback.onFaceScanResultCancel()
    }
}
