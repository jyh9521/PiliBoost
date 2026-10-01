# V2 播放器接入

2026-10-01：单 CDN 多 Range 已接入现有 localhost 视频代理，音频与 EDL 保持原链路。4/8/12/16 和独立 Multi-Range Auto 可选，默认仍 OFF。

并发必须存在强 ETag；以元数据响应确定总长度，每片 If-Match、206、Content-Range、Content-Length、identity 和实际正文均严格校验。无强 ETag 自动保持原单连接代理，diagnostics.parallelStatus 显示 missingStrongValidator；不声称这种情况启用了并发。

Auto 从4路开始：持续5秒低缓冲且实际聚合转发不足目标后每次加4，最多16；达到码率×安全系数目标停止增加，缓冲>=20秒每5秒减4。暂停或码率未知不增长。并发变化仅作用于下一窗口，不取消正在交付的正确分片。

每片256 KiB，重排最多4 MiB，session RAM LRU缓存最多8 MiB，前后窗口各4 MiB；不预读整个视频，不写磁盘。缓存精确绑定签名URI、强ETag、总长度与offset，返回只读载荷；新representation不复用，网络变化清缓存，关闭会话释放。应用载荷预算不是OS socket或进程RSS上限。

新请求取消旧代，等待旧consumer subscription与有界上游finally后再开启窗口；旧代结果不进入新seek响应。HEAD/416不启动分片。原生reader提前关闭不当作CDN错误；真正上游协议/下载失败触发现有恢复原始播放源链路。

验证包含localhost完整、闭区间、开放区间、suffix、强校验回落、validator变化、重叠seek、cache LRU/隔离、并发策略和Windows原生media_kit/mpv EDL视频+直连音频、seek30、暂停/速率/源恢复。Android真实视频效果留给最终安装包实机验收。
