# V4 效果诊断与兼容性观测

本阶段不放宽分片资源一致性要求，不把缓存输出包装成网络加速。默认仍OFF；既有CDN与代理模式保留。

## 三种计量
- networkReceivedBps/Bytes：Dart读到的远端正文，包括探测、重试和失败片已收到的正文。不含HTTP/TLS/socket开销，不含仅取headers后关闭而未读出的正文。
- networkForwardedBps/Bytes：新下载且通过校验后按offset交给播放器响应的正文。失败片不计入；不同seek重复输出仍计入，因此不是去重goodput。
- cacheForwardedBps/Bytes：从session RAM缓存交给播放器响应的正文。不产生新的媒体正文下载；仍可能发送元数据请求确认资源身份。

三组速率均是约3秒窗口，采用100ms桶，每组最多30桶；累计计数跨seek保留。proxyThroughputBps为网络+缓存输出。aggregateBps和Auto决策只使用网络顺序输出，不再让缓存命中抬高网络能力估计。音频仍直连，不计入以上视频指标。预启动窗口不足3秒时使用已运行时间。

## 并发与回落
observedConcurrency是已完成有效分片时记录的会话峰值上游在途请求数，不是当前活跃数，也不是性能收益证明。concurrency是窗口连接上限，activeRanges为当前在途数。诊断区分“已启用分片但未观测多路”、“已观测并发”、“缺校验回落单连接”、“恢复原始播放源”。缓存命中/小Range可能没有多路下载。

validatorStatus区分unmeasured/missing/weak/strong/unsupported，不输出ETag原值。poolRejectedCandidates及poolRejectionReasons统计锚点不一致、协议/状态/ETag错误等原因，不输出签名URI、私有route或token。

## 后续兼容性设计
弱ETag只证明语义等价，不能作为字节拼接依据；Last-Modified时间粒度与源站实现不保证同字节版本；相同长度与头尾锚点也不证明中间相同。保持现有单连接回退，下一阶段需先收集真实响应能力分布，再决定是否引入可信整资源hash/manifest提供的分片hash，或有明确不可变资源契约的适配器。没有上述依据不开放无validator跨响应拼接。

## 验证
新增窗口衰减/累积/缓存分流/有界桶/负数保护、状态说明、UI渲染与真实localhost缓存重放测试；已有pool测试补充拒绝原因检查。原生EDL、seek、音频、失败回退测试继续保留。自动化结果不替代Android真实吞吐或OFF/ON收益验收。
