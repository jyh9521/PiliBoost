<div align="center">
<!-- PiliBoost Accelerator integration point: fork-specific documentation. -->
    <img width="200" height="200" src="assets/images/logo/logo.png">
</div>

## PiliBoost · 0.1.0 发布准备

基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的自适应 CDN 与有界流媒体加速客户端。
主仓库为 [jyh9521/PiliBoost](https://github.com/jyh9521/PiliBoost)，上游仅作为架构参考与同步来源。

### 播放加速

音视频设置 → **播放加速 / Streaming Accelerator**，默认 **OFF**；设置在下次加载视频或切换画质时生效。

| 模式 | 当前实现 |
| --- | --- |
| OFF | 原播放链路，不创建加速请求 |
| Auto / Smart CDN | 持续低缓冲时有限 Range 探测、EWMA 优选、切换冷却与原源回退 |
| Proxy | 视频单连接本地 Range 代理，音频直连 |
| Multi-Range 4/8/12/16 | 单 CDN 有界分片并发，按序输出与 RAM 缓存 |
| Multi-Range Auto | 4 路起步，按缓冲与网络顺序输出速率调整，受并发上限约束 |
| Multi-CDN Auto | 实验模式；强 ETag、总长度与头尾采样一致后使用备用线路 |

并发上限可选 4/8/12/16 路，缓存预算可选 4/8/16 MiB，重排载荷最多 4 MiB。
无可传输的强 ETag 时保持单连接；失败尝试原源恢复。缓存不写磁盘，预算不是进程总内存上限。
直播、音频并发以及任意 CDN 的无校验拼接不在当前实现中。

### 如何验证

诊断页分别显示网络接收、网络顺序输出、缓存输出、实际观测并发、缓冲和 CDN 能力/降级原因。
可复制脱敏 JSON，分别记录 OFF/ON 并复制对照。对照仅为手工快照，不自动证明同视频或加速收益。
统一实机测试应保持相同视频、画质、位置与网络，观察持续播放、seek、切画质、后台/PiP和网络切换。
当前自动化与受控原生播放验证已完成；真实 CDN 收益及 Android 长时间播放仍待统一验收。

### 发布与构建

当前版本为 **0.1.0+2**，Android release 包名为 `com.jyh9521.piliboost`，显示名称为 **PiliBoost**。
release 使用独立发布密钥；此前 `com.example.piliplus.debug` 测试包独立保留，数据不会自动迁移。
从本仓库 [Releases](https://github.com/jyh9521/PiliBoost/releases) 获取已发布构建；本轮处于发布准备阶段，不把 release 构建等同于稳定版验收。
[构建与签名说明](docs/accelerator/RELEASE.md) · [V8 设置与导出](docs/accelerator/V8SETTINGS.md) · [验证说明](docs/accelerator/VALIDATION.md) · [算法署名](NOTICE)。

<div align="center">
    <h1>PiliBoost</h1>
<div align="center">

中文 | [English](README.en.md)

![GitHub repo size](https://img.shields.io/github/repo-size/jyh9521/PiliBoost)
![GitHub Repo stars](https://img.shields.io/github/stars/jyh9521/PiliBoost)
![GitHub all releases](https://img.shields.io/github/downloads/jyh9521/PiliBoost/total)
</div>
    <p>使用Flutter开发的BiliBili第三方客户端</p>

<img src="assets/screenshots/510shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="home" />
<br/>
<img src="assets/screenshots/main_screen.png" width="96%" alt="home" />
<br/>
</div>


<br/>

## 上游基础功能与平台

以下平台/功能清单继承自 PiliPlus；不表示 PiliBoost 加速功能已完成所有平台实机验收。

### 适配平台

- [x] Android
- [x] iOS
- [x] Pad
- [x] Windows
- [x] Linux

[![Packaging status](https://repology.org/badge/vertical-allrepos/piliplus.svg)](https://repology.org/project/piliplus/versions)

## refactor

- [ ] gRPC [wip]
- [x] 用户界面
- [x] 其他

## feat

- [x] 编辑动态
- [x] DLNA 投屏
- [x] 离线缓存/播放
- [x] 移动端支持点击弹幕悬停，点赞、复制、举报 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 播放音频
- [x] 跳过番剧片头/片尾
- [x] 安卓端 `loudnorm` 适配 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] Win/Mac 支持极验、短信登录 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 视频截取动图 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] AI 原声翻译
- [x] SuperChat
- [x] 播放课堂视频
- [x] 发起投票
- [x] 发布动态/评论支持`富文本编辑`/`表情显示`/`@用户`
- [x] 修改消息设置
- [x] 修改聊天设置
- [x] 展示折叠消息
- [x] 查看用户图文
- [x] 动态话题
- [x] 直播分区
- [x] 分享`视频`/`番剧`/`动态`/`专栏`/`直播`至消息
- [x] 创建/修改/删除关注分组
- [x] 移除粉丝
- [x] 直播弹幕发送表情
- [x] 收藏夹排序
- [x] 稍后再看 ~~`未看`~~ / `未看完` / ~~`已看完`~~ 分类
- [x] WebDAV 备份/恢复设置
- [x] 保存评论/动态
- [x] 高级弹幕 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 取消/置顶评论
- [x] 记笔记
- [x] 多账号支持 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 屏蔽带货动态/评论
- [x] 互动视频
- [x] 发评/动态反诈
- [x] 高能进度条
- [x] 滑动跳转预览视频缩略图
- [x] Live Photo
- [x] 复制/移动/排序收藏夹/稍后再看视频
- [x] 超分辨率
- [x] 合并弹幕
- [x] 会员彩色弹幕
- [x] 播放全部/继续播放/倒序播放
- [x] Cookie登录
- [x] 显示视频分段信息
- [x] 调节字幕大小
- [x] 调节全屏弹幕大小
- [x] 收藏夹/稍后再看多选删除
- [x] 搜索用户动态
- [x] 直播弹幕
- [x] 修改头像/用户名/签名/性别/生日
- [x] 创建/编辑/删除收藏夹
- [x] 评论楼中楼查看对话
- [x] 评论楼中楼定位点击查看的评论
- [x] 评论楼中楼按热度/时间排序
- [x] 评论点踩
- [x] 私信发图
- [x] 投币动画
- [x] 取消/追番，更新追番状态
- [x] 取消/订阅合集
- [x] SponsorBlock
- [x] 显示视频完整合集
- [x] 三连动画
- [x] 番剧三连
- [x] 带图评论
- [x] 视频TAG
- [x] 筛选搜索
- [x] 转发动态
- [x] 合集图片
- [x] 删除/置顶/撤回私信
- [x] 举报用户/评论/视频/动态
- [x] 删除/发布/置顶文本/图片动态
- [x] 其他

## opt

- [x] 专栏界面
- [x] 私信界面
- [x] 收藏面板
- [x] PIP
- [x] 视频封面
- [x] 回复界面
- [x] 系统通知
- [x] 评论显示
- [x] 亮度调节
- [x] 视频播放
- [x] 视频staff
- [x] 防止bottomsheet遮挡全屏视频
- [x] 其他

## fix

- [x] 番剧分集点赞/投币/收藏
- [x] bugs

<br/>

## 功能

- [x] 推荐视频列表(app端)
- [x] 最热视频列表
- [x] 热门直播
- [x] 番剧列表
- [x] 屏蔽黑名单内用户视频
- [x] 无痕模式（播放视为未登录）
- [x] 游客模式（推荐视为未登录）

- [x] 用户相关
  - [x] 粉丝、关注用户、拉黑用户查看
  - [x] 用户主页查看
  - [x] 关注/取关用户
  - [x] 离线缓存
  - [x] 稍后再看
  - [x] 观看记录
  - [x] 我的收藏
  - [x] 站内私信

- [x] 动态相关
  - [x] 全部、投稿、番剧分类查看
  - [x] 动态评论查看
  - [x] 动态评论回复功能

- [x] 视频播放相关
  - [x] 双击快进/快退
  - [x] 双击播放/暂停
  - [x] 垂直方向调节亮度/音量
  - [x] 垂直方向上滑全屏、下滑退出全屏
  - [x] 水平方向手势快进/快退
  - [x] 全屏方向设置
  - [x] 倍速选择/长按2倍速
  - [x] 硬件加速（视机型而定）
  - [x] 画质选择（高清画质未解锁）
  - [x] 音质选择（视视频而定）
  - [x] 解码格式选择（视视频而定）
  - [x] 弹幕
  - [x] 字幕
  - [x] 记忆播放
  - [x] 视频比例：高度/宽度适应、填充、包含等

- [x] 搜索相关
  - [x] 热搜
  - [x] 搜索历史
  - [x] 默认搜索词
  - [x] 投稿、番剧、直播间、用户搜索
  - [x] 视频搜索排序、按时长筛选

- [x] 视频详情页相关
  - [x] 视频选集(分p)切换
  - [x] 点赞、投币、收藏/取消收藏
  - [x] 相关视频查看
  - [x] 评论用户身份标识
  - [x] 评论(排序)查看、二楼评论查看
  - [x] 主楼、二楼评论回复功能
  - [x] 评论点赞
  - [x] 评论笔记图片查看、保存

- [x] 设置相关
  - [x] 画质、音质、解码方式预设
  - [x] 图片质量设定
  - [x] 主题模式：亮色/暗色/跟随系统
  - [x] 震动反馈(可选)
  - [x] 高帧率
  - [x] 自动全屏
  - [x] 横屏适配
- [ ] 等等

<br/>

## 下载

可以从 [Releases](https://github.com/jyh9521/PiliBoost/releases) 下载，或克隆仓库拉取代码后在本地编译。

<br/>

## 声明

此项目（PiliBoost，基于 PiliPlus）是个人为了兴趣而开发，仅用于学习和测试，请于下载后24小时内删除。
所用API皆从官方网站收集，不提供任何破解内容。
在此致敬原作者：[guozhigq/pilipala](https://github.com/guozhigq/pilipala)
在此致敬上游作者：[orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)
本仓库做了更激进的修改，感谢原作者的开源精神。

感谢使用


<br/>

## 致谢

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://pub.dev/packages/dio)
- 等等

<br/>
<br/>
<br/>

## Star History

<a href="https://star-history.dera.page/#jyh9521/PiliBoost&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=jyh9521/PiliBoost&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=jyh9521/PiliBoost&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=jyh9521/PiliBoost&type=Date" />
 </picture>
</a>
