import Foundation

enum JotlySecrets {
    static var deepSeekAPIKey: String {
        value("DEEPSEEK_API_KEY", userDefaultsKeys: ["deepseek_api_key"])
    }

    static var dashScopeAPIKey: String {
        value("DASHSCOPE_API_KEY", userDefaultsKeys: ["dashscope_api_key"])
    }

    static var mimoLLMAPIKey: String {
        value("MIMO_LLM_API_KEY", userDefaultsKeys: ["mimo_llm_api_key"])
    }

    static var doubaoASRAccessToken: String {
        value("DOUBAO_ASR_ACCESS_TOKEN", userDefaultsKeys: ["doubao_asr_access_token"])
    }

    static var aliyunASRAPIKey: String {
        value("ALIYUN_ASR_API_KEY", userDefaultsKeys: ["aliyun_asr_api_key"])
    }

    static var mimoASRAPIKey: String {
        value("MIMO_ASR_API_KEY", userDefaultsKeys: ["mimo_asr_api_key"])
    }

    private static func value(_ key: String, userDefaultsKeys: [String]) -> String {
        for defaultsKey in userDefaultsKeys {
            if let value = nonEmpty(UserDefaults.standard.string(forKey: defaultsKey)) {
                return value
            }
        }
        if let value = nonEmpty(ProcessInfo.processInfo.environment[key]) {
            return value
        }
        return nonEmpty(localSecrets[key] as? String) ?? ""
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static let localSecrets: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "LocalSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }()
}
