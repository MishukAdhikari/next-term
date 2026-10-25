import Foundation
@testable import NextTermCore

/// Password-manager exports for the import's tests, written by hand from the formats' published shapes with made-up
/// items: no export from any real vault. Each key-shaped value is a provider's head and filler, put together at run
/// time.
enum ExportFixtures {
    typealias F = SecretSourcesFixtures

    static let tavily = "tvly-" + "dev-" + "7Hq2Lm9Xc4Vb8Nz1Kp6Rt3Wd"
    static let linear = "lin_" + "api_" + "Zq8Wm3Xr7Tn2Vb6Kc1Pd5Hf9Lj4Gs0Ay8Ue3Io7"
    static let anthropic = "sk-" + "ant-" + "api03-" + "Mb7Qx2Lr9Vt4Nc8Zp1Hk6Wd3Js5Fg0Ay"
    static let webhook = "whsec" + "_" + "Lq4Nv8Rx2Tz6Wb0Yc3Ad7Ef1Gh5Jk9Mp"
    /// A site's password: no key's shape.
    static let bankPassword = "Correct-Horse-Battery-77"
    static let historyPassword = "Old-History-" + "Pw-Qz81Wx-2025"
    static let totpSeed = "KRSXG5CT" + "MVRXEZLU"
    static let username = "made-up-user@example.invalid"
    /// Free text in a `bws` note, holding a key's shape: never read.
    static let noteToken = "ghp_" + "Nt5Rk9Wm2Xq7Vb3Lc8Zd1Hf6Jp4Gs0Ay"

    /// A login "Tavily" whose password has Tavily's shape, a secure note "Linear" with a hidden field, a login
    /// "Bank" with a site password, and a card, which is never read.
    static func bitwardenItems(notes: String? = nil, reprompt: Int = 0) -> String {
        let noteText: String = notes.map(jsonString) ?? "null"
        return """
            [
              {
                "id": "00000000-0000-4000-8000-000000000001", "organizationId": null, "folderId": null,
                "type": 1, "reprompt": 0, "name": "Tavily", "notes": null, "favorite": false,
                "login": {
                  "uris": [{"match": null, "uri": "androidapp://com.example.madeup"},
                           {"match": null, "uri": "https://app.tavily.com/home"}],
                  "username": "\(username)", "password": "\(tavily)", "totp": "\(totpSeed)"
                },
                "passwordHistory": [{"lastUsedDate": "2026-01-01T00:00:00.000Z", "password": "\(historyPassword)"}],
                "collectionIds": null
              },
              {
                "id": "00000000-0000-4000-8000-000000000002", "organizationId": null, "folderId": null,
                "type": 2, "reprompt": \(reprompt), "name": "Linear", "notes": \(noteText), "favorite": false,
                "secureNote": {"type": 0},
                "fields": [{"name": "LINEAR_API_KEY", "value": "\(linear)", "type": 1, "linkedId": null},
                           {"name": "workspace", "value": "made-up-team", "type": 0, "linkedId": null}]
              },
              {
                "id": "00000000-0000-4000-8000-000000000003", "organizationId": null, "folderId": null,
                "type": 1, "reprompt": 0, "name": "Bank", "notes": null, "favorite": false,
                "login": {"uris": [{"match": null, "uri": "https://bank.example.com/login"}],
                          "username": "\(username)", "password": "\(bankPassword)", "totp": null}
              },
              {
                "id": "00000000-0000-4000-8000-000000000004", "organizationId": null, "folderId": null,
                "type": 3, "reprompt": 0, "name": "Card", "notes": null, "favorite": false,
                "card": {"cardholderName": "Made Up", "number": "4111111111111111", "code": "123"}
              }
            ]
            """
    }

    /// Bitwarden's unencrypted `.json` export: the items with their folders.
    static func bitwardenExport(notes: String? = nil, reprompt: Int = 0) -> String {
        #"{"encrypted": false, "folders": [], "items": "# + bitwardenItems(notes: notes, reprompt: reprompt) + "}"
    }

    /// An encrypted export, by the account's key: its values are ciphertext.
    static let bitwardenEncrypted = """
        {"encrypted": true, "encKeyValidation_DO_NOT_EDIT": "2.bWFkZS11cA==|bWFkZS11cA==|bWFkZS11cA==",
         "folders": [], "items": [{"id": "00000000-0000-4000-8000-000000000001", "type": 1,
         "name": "2.bWFkZS11cA==|bWFkZS11cA==|bWFkZS11cA=="}]}
        """

    /// A password-protected export: one sealed blob.
    static let bitwardenProtected = """
        {"encrypted": true, "passwordProtected": true, "salt": "bWFkZS11cA==", "kdfType": 0,
         "kdfIterations": 600000, "encKeyValidation_DO_NOT_EDIT": "2.bWFkZS11cA==|bWFkZS11cA==",
         "data": "2.bWFkZS11cA==|bWFkZS11cA==|bWFkZS11cA=="}
        """

    /// A text as a JSON string, quotes and escapes included.
    static func jsonString(_ text: String) -> String {
        let data: Data = (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 1Password and Bitwarden Secrets Manager

extension ExportFixtures {
    /// One API Credential item as `op item get --format json --reveal` prints it, titled with its key's name.
    static func opAPICredential(title: String, value: String, site: String) -> String {
        """
        {
          "id": "madeupitem\(title.count)00000000000000", "title": "\(title)", "version": 1,
          "vault": {"id": "madeupvault0000000000000001", "name": "Private"},
          "category": "API_CREDENTIAL", "last_edited_by": "MADEUPUSER0000000000000001",
          "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-01T00:00:00Z",
          "urls": [{"label": "website", "primary": true, "href": "\(site)"}],
          "fields": [
            {"id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain",
             "value": "Made-up note naming \(noteToken)"},
            {"id": "username", "type": "STRING", "label": "username", "value": "\(username)"},
            {"id": "credential", "type": "CONCEALED", "label": "credential", "value": "\(value)"},
            {"id": "type", "type": "MENU", "label": "type", "value": "other"}
          ]
        }
        """
    }

    static var opAnthropic: String {
        let site = "https://console.anthropic.com/settings/keys"
        return opAPICredential(title: "ANTHROPIC_API_KEY", value: anthropic, site: site)
    }

    static var opTavily: String {
        opAPICredential(title: "TAVILY_API_KEY", value: tavily, site: "https://app.tavily.com/home")
    }

    /// A Database item with its password and a second concealed field in a section, and a one-time code.
    static let opDatabase = """
        {
          "id": "madeupdatabase000000000001", "title": "made-up-db", "category": "DATABASE",
          "fields": [
            {"id": "username", "type": "STRING", "purpose": "USERNAME", "label": "username", "value": "\(username)"},
            {"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password",
             "value": "made-up-db-pass-2026"},
            {"id": "admintoken", "type": "CONCEALED", "label": "admin token", "value": "\(webhook)",
             "section": {"id": "extra", "label": "Extra"}},
            {"id": "otp", "type": "OTP", "label": "one-time password", "value": "\(totpSeed)"}
          ]
        }
        """

    /// A 1PUX export's `export.data`: an API Credential, an archived item, a login with history, a Password item and a
    /// card, in one vault.
    static let onePUXData = """
        {"accounts": [{"attrs": {"accountName": "Made Up", "name": "Made Up", "email": "\(username)",
          "uuid": "MADEUPACCOUNT", "domain": "https://my.1password.com/"},
          "vaults": [{"attrs": {"uuid": "madeupvault", "name": "Private", "type": "P"}, "items": [
            {"uuid": "item1", "favIndex": 0, "createdAt": 1760000000, "updatedAt": 1760000000, "state": "active",
             "categoryUuid": "112", "details": {"loginFields": [], "notesPlain": "Made-up note naming \(noteToken)",
               "sections": [{"title": "", "name": "", "fields": [
                 {"title": "credential", "id": "credential", "value": {"concealed": "\(anthropic)"},
                  "indexAtSource": 0, "guarded": true, "multiline": false, "dontGenerate": true},
                 {"title": "username", "id": "username", "value": {"string": "\(username)"},
                  "indexAtSource": 1, "guarded": false, "multiline": false, "dontGenerate": false}]}],
               "passwordHistory": []},
             "overview": {"subtitle": "", "urls": [], "title": "Anthropic",
               "url": "https://console.anthropic.com/settings/keys", "ps": 0, "pbe": 0.0, "pgrng": false}},
            {"uuid": "item2", "state": "archived", "categoryUuid": "112", "details": {"loginFields": [],
               "sections": [{"title": "", "fields": [{"title": "credential", "id": "credential",
                 "value": {"concealed": "\(webhook)"}}]}]},
             "overview": {"title": "Old key", "url": ""}},
            {"uuid": "item3", "state": "active", "categoryUuid": "001", "details": {"loginFields": [
                 {"value": "\(username)", "id": "", "name": "username", "fieldType": "E", "designation": "username"},
                 {"value": "\(bankPassword)", "id": "", "name": "password", "fieldType": "P",
                  "designation": "password"}],
               "sections": [], "passwordHistory": [{"value": "\(historyPassword)", "time": 1750000000}]},
             "overview": {"title": "Bank", "url": "https://bank.example.com/login",
               "urls": [{"label": "", "url": "https://bank.example.com/login"}]}},
            {"uuid": "item4", "state": "active", "categoryUuid": "005",
             "details": {"loginFields": [], "sections": [], "password": "\(tavily)"},
             "overview": {"title": "Tavily", "urls": [{"label": "website", "url": "https://app.tavily.com/home"}]}},
            {"uuid": "item5", "state": "active", "categoryUuid": "002", "details": {"loginFields": [],
               "sections": [{"title": "", "fields": [{"title": "verification number", "id": "cvv",
                 "value": {"concealed": "123"}}]}]},
             "overview": {"title": "Card"}}
          ]}]}]}
        """

    /// `bws secret list --output json`: three secrets in two projects, one named in words, and a note with a key's
    /// shape.
    static let bwsList = """
        [
          {"object": "secret", "id": "00000000-0000-4000-8000-0000000000a1", "organizationId": "made-up-org",
           "projectId": "made-up-project-1", "key": "OPENAI_API_KEY", "value": "\(F.openAI)",
           "note": "Rotated by hand: \(noteToken)", "creationDate": "2026-10-01T00:00:00Z",
           "revisionDate": "2026-10-01T00:00:00Z"},
          {"object": "secret", "id": "00000000-0000-4000-8000-0000000000a2", "organizationId": "made-up-org",
           "projectId": "made-up-project-1", "key": "PINECONE_API_KEY", "value": "\(F.pinecone)", "note": "",
           "creationDate": "2026-10-01T00:00:00Z", "revisionDate": "2026-10-01T00:00:00Z"},
          {"object": "secret", "id": "00000000-0000-4000-8000-0000000000a3", "organizationId": "made-up-org",
           "projectId": "made-up-project-2", "key": "db password", "value": "made-up-db-pass-2026", "note": "",
           "creationDate": "2026-10-01T00:00:00Z", "revisionDate": "2026-10-01T00:00:00Z"}
        ]
        """
}

// MARK: - CSV exports

extension ExportFixtures {
    /// Bitwarden's `.csv` export: a login with a key's shape, a note with a field and a `KEY=value` line, and a login
    /// with a site password that asks for the master password again.
    static var bitwardenCSV: String {
        """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        ,,login,Tavily,,,0,https://app.tavily.com/home,\(username),\(tavily),\(totpSeed)
        Work,,note,Linear,"LINEAR_WEBHOOK_SECRET=\(webhook)","LINEAR_API_KEY: \(linear)",0,,,,
        ,1,login,Bank,,,1,"https://bank.example.com/login,https://bank.example.com/m",\(username),\(bankPassword),

        """
    }

    /// Chrome's (and every Chromium browser's) export: a site password, and a password with a key's shape.
    static var chromeCSV: String {
        """
        name,url,username,password,note
        github.com,https://github.com/login,\(username),\(bankPassword),
        api.example.com,https://www.api.example.com/,\(username),\(F.openAI),made-up note

        """
    }

    /// Apple Passwords: the title names the account, which a key's name must never carry.
    static var appleCSV: String {
        """
        Title,URL,Username,Password,Notes,OTPAuth
        github.com (\(username)),https://github.com/,\(username),\(bankPassword),,
        console.example.com (\(username)),https://console.example.com/,\(username),\(anthropic),,

        """
    }

    /// Firefox: no title, and its own sync account's row.
    static var firefoxCSV: String {
        """
        "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
        "https://bank.example.com","\(username)","\(bankPassword)",,"https://bank.example.com","{made-up-1}","1","1","1"
        "chrome://FirefoxAccounts","made-up","{""kSync"":""made-up""}","Firefox Accounts credentials",,"{made-up-2}","1","1","1"

        """
    }

    /// KeePassXC: a title that names a token over a password with no shape, an OpenAI key, and a site password.
    static var keePassXCCSV: String {
        """
        "Group","Title","Username","Password","URL","Notes","TOTP","Icon","Last Modified","Created"
        "Root","Groq token","","made-up-groq-pass-99","https://console.groq.com/keys","","","0","",""
        "Root","OpenAI","","\(F.openAI)","https://platform.openai.com/","","","0","",""
        "Root","Mail","\(username)","\(bankPassword)","https://mail.example.com/","","","0","",""

        """
    }

    /// LastPass: a login, and a secure note (its URL `http://sn`) holding a `KEY=value` line.
    static var lastPassCSV: String {
        """
        url,username,password,totp,extra,name,grouping,fav
        https://bank.example.com/,\(username),\(bankPassword),,,Bank,Money,0
        http://sn,,,,"OPENAI_API_KEY=\(F.openAI)",RAG keys,Dev,0

        """
    }

    /// 1Password's `.csv` export: an item, and an archived one, which is skipped.
    static var onePasswordCSV: String {
        """
        Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes
        Tavily API,https://app.tavily.com/home,\(username),\(tavily),,false,false,dev,
        Old Tavily,https://app.tavily.com/home,\(username),\(tavily.reversedText),,false,true,,

        """
    }

    static let plainLink = "https://platform.openai.com/settings/organization/api-keys"

    /// A plain `name,value` file, with a link column.
    static var plainCSV: String {
        """
        name,value,url
        OPENAI_API_KEY,\(F.openAI),\(plainLink)
        OPENAI_MODEL,gpt-5,
        pinecone-api-key,\(F.pinecone),

        """
    }
}
