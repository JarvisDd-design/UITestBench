public enum DropTargetPolicy {
    /// 设备运行时，手机屏是触摸面；把文件拖上去会被当成滑动/点击。
    /// 所以只有待机屏接收文件，运行时改用「素材」抽屉。
    /// 只有设备真正在运行时才拒绝；启动、停止、失败这些过渡状态仍然接收文件。
    public static func acceptsDrop(deviceRunning: Bool) -> Bool {
        !deviceRunning
    }
}
