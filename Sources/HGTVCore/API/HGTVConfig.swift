// HGTVConfig.swift
// 所有域名 / aid / UA / endpoint 严格来自原 APK (com.hgtv.star 1.3.7.3) 的 dex 字符串常量，
// 不自行发明。来源见 /root/workspace/decomp 下的反编译导出。

import Foundation

public enum HGTVConfig {

    // MARK: - 应用标识（字节系 aid）
    /// 番茄阅读 aid，设备注册与 X-SS-DP 头均使用此值
    public static let aid: Int = 8662
    public static let ssDP: String = "8662"

    // MARK: - 版本（用于 UA 中的 %VC% 与接口 version 参数）
    public static let versionName: String = "1.3.7.3"
    public static let versionCode: Int = 78
    /// UA 里的 %VC% 占位值
    public static let uaVersionCode: String = String(versionCode)

    // MARK: - 网络栈版本（来自 dex 中 device_register query）
    public static let cronetVersion: String = "8d40f833_2026-03-03"
    public static let ttnetVersion: String = "4.2.243.31-douyin"
    public static let quicVersion: String = "21ac1950 2025-11-18"

    // MARK: - User-Agent（伪装成番茄阅读客户端，dex 原文）
    public static func userAgent(model: String = "AppleTV", build: String = "ATV26") -> String {
        // dex: com.phoenix.read/%VC% (Linux; U; Android %OS%; zh_CN; %MODEL%; Build/%BUILD%; Cronet/...)
        let base = "com.phoenix.read/\(uaVersionCode) (Linux; U; Android 10; zh_CN; \(model); Build/\(build)"
        return base + "; Cronet/TTNetVersion:\(cronetVersion) QuicVersion:\(quicVersion))"
    }

    // MARK: - 业务域名
    public enum Host {
        /// 自建搜索中转站（dex: hongguoduanju.com）
        public static let hongguo = "hongguoduanju.com"
        /// 番茄内容接口（dex: api5-normal-*.fqnovel.com，reading.snssdk.com）
        public static let fqnovel = "api5-normal-lf.fqnovel.com"
        public static let readingSnssdk = "reading.snssdk.com"
        public static let novelSnssdk = "novel.snssdk.com"
        /// 字节账号体系
        public static let passport = "passport.snssdk.com"
        /// 设备注册（TTNet service）
        public static let deviceRegister = "log5-applog-lf.fqnovel.com"
        /// 播放调度 TNC（多 CDN，dex: tnc3-aliec2 / tnc3-alisc1 / tnc3-bjlgy / tnc11-aliec2）
        public static let tncHosts: [String] = [
            "tnc3-aliec2.zijieapi.com",
            "tnc3-alisc1.zijieapi.com",
            "tnc3-bjlgy.zijieapi.com",
            "tnc11-aliec2.zijieapi.com"
        ]
        /// 自有镜像 / 匿名头主机
        public static let mirrorHosts: [String] = ["luckysf.net", "iluckysf.net"]
        /// 图片 CDN
        public static let imageCDN = "p3-novel.byteimg.com"
    }

    // MARK: - API Endpoints（dex 原文路径）
    public enum Path {
        // 搜索（自建中转）
        public static let searchResult = "/api/search/result"          // ?query=
        public static let searchSuggestion = "/api/search/suggestion"  // ?query=

        // 内容（番茄短剧）
        public static let categoryLandpage = "/reading/distribution/category/landpage/v/"
        public static let recommendStatReport = "/reading/distribution/recommend_stat/report/v1/"
        public static let searchTab = "/reading/bookapi/search/tab/v"
        public static let searchSuggest = "/reading/bookapi/search/suggest/v:version/"
        public static let multiDetail = "/reading/bookapi/multi-detail/v"
        public static let bookmallTab = "/reading/bookapi/bookmall/tab/v"
        public static let bookshelfVideoInfo = "/reading/bookapi/bookshelf/video/info/v"
        public static let bookshelfVideoUpdate = "/reading/bookapi/bookshelf/video/update/v"
        public static let readHistoryList = "/reading/bookapi/read_history/list/v"
        public static let readHistoryUpdate = "/reading/bookapi/read_history/update/v"
        public static let readProgressUpload = "/reading/bookapi/read_progress/upload/v"
        public static let plan = "/reading/bookapi/plan/v:version/"
        public static let userInfo = "/reading/user/info/v1/"
        public static let userBasicInfo = "/reading/user/basic_info/get/v1/"
        public static let ugcActionMget = "/reading/ugc/action/mget/v"
        public static let subscribeList = "/reading/user/subscribe/list/v1/"
        public static let subscribeDelete = "/reading/user/subscribe/delete/v1/"

        // 播放模型
        public static let videoModel = "/novel/player/video_model/v1/"
        public static let videoDetail = "/novel/player/video_detail/v1/"
        public static let multiVideoPlayer = "/novel/player/multi_video_model/player/v1"
        public static let multiVideoPreload = "/novel/player/multi_video_model/preload/v1"
        public static let multiVideoModel = "/novel/player/multi_video_model/v1/"

        // 登录（字节 Passport）
        public static let passportGetQRCode = "/passport/web/get_qrcode/"
        public static let passportCheckQRConnect = "/passport/web/check_qrconnect/"
        public static let passportSendCode = "/passport/mobile/send_code/v1/"
        public static let passportSMSLogin = "/passport/mobile/sms_login/"
        public static let passportAccountInfo = "/passport/account/info/v2/"
        public static let passportTokenBeat = "/passport/token/beat/v2/"
        public static let passportUpsmsVerify = "/passport/upsms/verify/"
        public static let passportUpsmsGenTicket = "/passport/upsms/gen_verify_ticket/"

        // 设备注册
        public static let deviceRegister = "/service/2/device_register/"
    }

    // MARK: - device_register 完整 query（dex 原文）
    public static let deviceRegisterQuery: [String: String] = [
        "tt_data": "a",
        "cronet_version": cronetVersion,
        "ttnet_version": ttnetVersion,
        "use_store_region_cookie": "1"
    ]

    // MARK: - 签名相关常量（dex: LF0/C3, LF0/C1）
    public enum Signing {
        /// X-Gorgon 种子（dex: 539167016）
        public static let gorgonSeed: UInt32 = 539167016
        /// passport-sdk-version 头（dex: 5051452）
        public static let passportSDKVersion: String = "5051452"
        /// _rticket 滚动窗口次数（dex: while (i < 128)）
        public static let rticketWindow: Int = 128
    }

    // MARK: - 公共 header 键（dex 原文）
    public enum HeaderKey {
        public static let identity = "X-HGTV-Identity"
        public static let anonymous = "X-HGTV-Anonymous"
        public static let ttToken = "X-Tt-Token"
        public static let ttTokenLower = "x-tt-token"
        public static let ssDP = "X-SS-DP"
        public static let storeRegion = "X-Tt-Store-Region"
        public static let storeRegionSrc = "X-Tt-Store-Region-Src"
        public static let passportSDK = "passport-sdk-version"
        public static let gorgon = "X-Gorgon"
        public static let argus = "X-Argus"
        public static let ladon = "X-Ladon"
        public static let khronos = "X-Khronos"
        public static let cookie = "Cookie"
        public static let userAgent = "User-Agent"
    }
}