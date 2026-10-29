# 订阅影院 — iOS 15.6 原型

独立编写的订阅播放器原型，没有复制映匣源码或图形资源。

目前实现：单个 TVBox JSON 订阅地址保存、type 1/4 HTTP JSON 源筛选、分类、搜索、分页、详情、线路选集、AVPlayer 系统播放界面。实际源存在协议差异，type 4 并非全部兼容。

未实现：JAR/JS/Python 插件、网页嗅探和解析、请求头配置、收藏、历史、播放进度恢复、自定义播放错误界面。HTTP 地址不保证是可解码的媒体地址。

最低部署目标为 iOS 15.6，覆盖 15.6.1。当前 Windows 环境无法编译 Swift/iOS，尚未完成云端编译或真机验证，不能视为已可用的 IPA。

云端构建：将本文件夹放到仓库根目录的 SubscriptionPlayer/，将 .github/workflows/subscription-player.yml 移到仓库根目录同名位置。工作流会生成未签名 IPA，安装前需自行签名。工作流没有证书或 Apple 账号需求。

仅添加自己有权使用的订阅。为兼容 HTTP 源，原型允许非加密网络连接。
