// sign_cli.swift
// curl-impersonate TLS 指纹验证辅助：用项目真实 V5 签名链路（SignInterceptor + HCSignerV5，
// 与 Nbeedp app 完全同路径）生成 landpage 请求，输出 JSON 供 CI 用 curl-impersonate 发送。
//
// 用法: sign_cli <output.json>
// 输出: {"url": ..., "headers": {...}, "body_base64": ...(gzip 后 body)}
//
// 身份：RealDeviceRegister.presetIdentities[0]（池首 Redmi 23046PNC9C，
// device_id=3638697714281811，2026-11-24 redroid 原版 dump 活身份，
// 与 Python 标准答案 test_landpage_v2.py 同源）。
// 头集合：V5 sign 产出 + intercept 注入（Cookie/x-ss-dp/X-Tt-Store-Region(-Src)）
// + Accept-Encoding: gzip + Content-Type 小写 utf-8，与 test_landpage_v2.py 成功头集合对齐。

import Foundation

@main
struct SignCLI {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: sign_cli <output.json>\n", stderr)
            exit(2)
        }
        let outPath = args[1]

        do {
            let request = try buildSignedRequest()
            try writeJSON(request, to: outPath)
            // 自检诊断（stderr）
            fputs("sign_cli OK: url_len=\(request.url.count) headers=\(request.headers.count) body_gz=\(request.body.count)\n", stderr)
            fputs("  gorgon_len=\(request.headers["x-gorgon"]?.count ?? 0) (期望 52) medusa_b64_len=\(request.headers["x-medusa"]?.count ?? 0)\n", stderr)
            fputs("  khronos=\(request.headers["x-khronos"] ?? "") req_ticket=\(request.headers["x-ss-req-ticket"] ?? "")\n", stderr)
            if let url = URL(string: request.url), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let items = comps.queryItems {
                fputs("  query_keys=\(items.count) host=\(comps.host ?? "") path=\(comps.path)\n", stderr)
                let names = items.map { $0.name }
                fputs("  has klink_egdi=\(names.contains("klink_egdi")) ts=\(names.contains("ts")) _rticket=\(names.contains("_rticket"))\n", stderr)
            }
        } catch {
            fputs("sign_cli FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    struct Output {
        var url: String
        var headers: [String: String]
        var body: [UInt8]
    }

    /// 与 Nbeedp app 的 APIService.fetchLandpage 完全同款构造，仅替换网络发送方。
    static func buildSignedRequest() throws -> Output {
        // 1) 池首 Redmi 身份（klink_egdi 进 credentials.device，随 landpageFamily 白名单进 query）
        let id = RealDeviceRegister.presetIdentities[0]
        var device = id.deviceProfile ?? [:]
        device["klink_egdi"] = id.klinkEgdi
        let creds = AccountCredentials(
            cookie: id.cookieHeader,
            token: id.deviceToken,
            tsSign: "",
            deviceId: id.deviceID,
            installId: id.installID,
            cdid: id.cdid,
            openudid: id.openudid,
            expiresAt: 0,
            device: device)

        // 2) SignInterceptor（V5 路径，与 HTTPClient.request → intercept 同链路）
        let signer = RequestSigner()
        let registrar = DeviceRegistrar(signer: signer)
        let interceptor = SignInterceptor(signer: signer, registrar: registrar, credentials: creds)

        // 3) landpage payload（offset=0 首页，与 fetchLandpage / test_landpage_v2.py 一致）
        let payload: [String: Any] = [
            "filter_ids": "",
            "req_scene": "default",
            "offset": 0,
            "need_selector_panel": true,
            "limit": 100,
            "select_items": ["genre": [String](), "sort": ["hot_score"]],
            "session_id": "",
            "req_type": "default",
            "client_req_type": 3,
        ]
        let bodyPlain = try JSONSerialization.data(withJSONObject: payload, options: [])
        // landpage body 必须 gzip（x-ss-stub/gorgon 绑定 gzip 后字节）
        let gz = Gzip.compress(bodyPlain)

        // 4) landpage 族 query 覆写（73532/7.3.5.32 + channel=69310258a，同 fetchLandpage）
        let family: [String: String] = [
            "version_code": "73532",
            "version_name": "7.3.5.32",
            "manifest_version_code": "73532",
            "update_version_code": "73532",
            "pv_player": "73532",
            "channel": "69310258a",
        ]

        let base = "https://" + HGTVConfig.Host.sinfonlineb + HGTVConfig.Path.categoryLandpage
        let req = interceptor.intercept(baseURL: base,
                                        params: family,
                                        body: [UInt8](gz),
                                        landpageFamily: true)

        // 5) 头集合收尾：与 test_landpage_v2.py 成功头集合对齐
        var headers = req.headers
        headers["Accept-Encoding"] = "gzip"
        if headers["Content-Type"] != nil {
            headers["Content-Type"] = "application/json; charset=utf-8"
        }
        return Output(url: req.url, headers: headers, body: req.body ?? [UInt8](gz))
    }

    static func writeJSON(_ r: Output, to path: String) throws {
        let obj: [String: Any] = [
            "url": r.url,
            "headers": r.headers,
            "body_base64": Data(r.body).base64EncodedString(),
        ]
        let json = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: path))
    }
}