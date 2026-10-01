# V2 单 CDN 分块核心（未接入播放器）

日期：2026-10-01。开发分支：feature/streaming-accelerator。

## 本轮内容
新增 RangeDownloader、RangeResource、RangeCancellation、OrderedRangeScheduler。只使用一个不可变远端资源；URI、总长度和可选强 ETag 由调用方提供，保留签名 query。每片校验 206、精确起止/总长度/正文长度、identity 编码；提供 ETag 时使用 If-Match 并逐片验证相同强 ETag。

默认256 KiB分片、4路窗口，最多16路、单片最多1 MiB；窗口总有效载荷 <= maxMemoryBytes（默认4 MiB）。构造时拒绝小于 concurrency×chunkBytes 的预算。每批有限 Future 按offset输出；暂停消费者不启动下一窗口。所有迟到 Future 立即有错误处理，不允许乱序输出或忽略错误。

每片默认最多2次尝试，最多配置3次；每次连接/headers/全正文均在8秒绝对deadline内，重试退避最多1秒。仅408、500/502/503/504、网络/截断等暂时错误重试原Range。403/412/416/429、200忽略Range、redirect、协议/ETag不一致不重试，不换CDN，不下载完整文件代替分片。

invalidate取消本代所有上游；消费者必须取消旧subscription并等待finally清理，再开启seek代。拒绝同时多个reader，防止跨代累积重排内存。暂停状态不能仅调用invalidate后就再开reader，需要订阅方cancel。应用预分配载荷和重排窗口有预算；该预算不等同进程RSS上限，不覆盖操作系统socket缓冲或消费者自己保留的输出。

## 计量
RangeDownloader记录attempts/retries/upstreamBytes（包含失败片已经读取的字节）及active/peak请求。Scheduler记录本次read的deliveredBytes/墙钟时间，包含暂停等待，不将每连接测速相加。输出计量不是跨seek全会话去重goodput，不声称所有交给stream的字节最终被播放器消费。

## 验证
真实localhost测试覆盖完整和子区间、签名/header保留、4/8/12/16路、明确乱序完成后准确重组、消费者背压、代取消、不合法预算、错误状态/总长度/ETag/编码、有限重试、绝对deadline和原始TCP截断响应。截断测试每次只回32字节，共重试2次，上游计64字节且未产生可消费chunk。
本轮未修改模式enum、设置UI、现有代理/player接入或native依赖。多Range仍禁用；未生成一个声称已支持播放器并发的新APK。

## 下一步
先确认V1c代理Android播放、seek/音画/后台和恢复表现；再做representation元数据获取与validator策略、有限session cache、播放器请求桥接及动态并发评估。没有强ETag时，总长度+URI不足以证明内容永不变化，须制定可靠资源身份和回退策略后接入。此核心不提供多CDN、一边验证一边拼接未知资源或长时间磁盘缓存。

协议参考：https://www.rfc-editor.org/rfc/rfc9110.html#name-if-match
Dart transport：https://api.dart.dev/dart-io/HttpClientRequest/abort.html
