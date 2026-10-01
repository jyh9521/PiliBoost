# V5 多 CDN 恢复与建池稳定性

本轮保持强ETag、总长度和头尾校验要求，不放开无validator拼接，不改变默认OFF或原始播放回退。

## 冷却后的半开恢复
暂时错误仍最多一次跨线路failover。失败线路进入30秒冷却；冷却结束后标记needsRecovery，仅当该线路active==0时可分配一个真实需求Range作为恢复探测。探测成功才解除限制，失败重新冷却，显式取消只释放在途槽位，不伪造成功。其他任务继续走健康线路，避免旧测速很快的故障线路在同一16路窗口中被集中重试。

诊断新增recoveryProbePending与recoveryState（ready/cooling/halfOpen/excluded）；403/429、协议和ETag错误仍维持终止/原始链路恢复策略，不借半开恢复扩大授权请求。

## 可选备用验证预算
建池使用独立validation取消令牌，父会话令牌只通过attach转发取消；内部8秒预算不会污染父令牌。主源头尾完整验证是必要条件；主源失败不建立pool。只有备用候选验证消耗完总预算时，记录validationBudget并使用已验证主源。显式seek/关闭取消优先：父令牌取消始终抛出RangeCancelled，不把旧代建池当成成功。

失败或取消清理未完成lanes，累计接收字节保留；允许后续重新prepare而不叠加重复主源。并行prepare明确拒绝；已prepare的pool也先检查父取消状态。sampleBytes必须在1..256KiB范围内，timeout为正，cooldown非负，构造时验证。

## 验证
真实localhost新增半开单请求闸门、备用预算到期主源继续下载、显式取消、重建去重与3个非法预算测试。半开测试使用注入单调时钟推进30秒，不等待实机网络故障。完整模块与Windows native EDL回归继续保留；Android APK仍需实际长播/网络切换验收。
