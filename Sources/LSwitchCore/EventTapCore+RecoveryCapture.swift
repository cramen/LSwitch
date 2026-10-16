import Dispatch

extension EventTapCore {
    #if DEBUG
    /// С момента создания не декодирует произвольный ввод, даже до attach и после handover.
    public static func recoveryFixtureTap() -> EventTapCore {
        EventTapCore(handler: { _ in }, processingQueue: DispatchQueue(label: "lswitch.recovery.fixture"),
                     recoveryCaptureRouter: RecoveryCaptureRouter(bypassRawProcessing: true))
    }
    #endif

    @MainActor
    func scheduleRecoveryCaptureExpiry(_ attachment: RecoveryCaptureAttachment) {
        attachment.scheduleExpiry()
    }
}
