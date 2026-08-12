import Foundation

@MainActor
protocol PlayerEngine: AnyObject {
    var state: PlayerState { get }
    /// 完成回调:当前曲目播完时调用(替代旧的 isPlaying 翻转检测)。
    /// 由 PlaybackService 设置,用于无缝推进队列 + 预加载下一首。
    var onCompletion: (@MainActor () -> Void)? { get set }
    func load(_ track: TrackSnapshot) async throws
    /// 预加载下一首到备用播放器节点(不调度、不播放)。
    func prepare(_ track: TrackSnapshot) async
    /// 播放已预加载的曲目:调度到非活跃节点 + 播放 + 交换节点 + 更新 state。
    /// 返回 true 表示成功切换;false 表示无预加载曲目。
    @discardableResult
    func playPrepared() -> Bool
    func play()
    func pause()
    func toggle()
    func seek(to time: Double)
    func setVolume(_ v: Float)
    func setEQ(_ bands: [EQBand])
    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void)
    func removeSpectrumTap()
}