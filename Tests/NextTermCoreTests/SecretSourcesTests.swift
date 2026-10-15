import Foundation
import Testing
@testable import NextTermCore

/// What a file's values become in the import's preview: which look like keys and start ticked, which are listed with a
/// note or a reason, and which are only counted as values that aren't keys. Every value here is made up.
@Suite struct SecretSourcesTests {
    typealias F = SecretSourcesFixtures
    static let now = Date(timeIntervalSince1970: 1_791_000_000)

    private static func classify(_ name: String, _ value: String, sourceSays: Bool = false) -> SecretSources.Classified {
        SecretSources.classify(name: name, value: value, sourceSays: sourceSays, now: now)
    }

    private static func ticked(_ name: String, _ value: String) -> Bool {
        guard case .row(_, let ticked, _, let refusal) = classify(name, value) else { return false }
        return ticked && refusal == nil
    }

    private static func note(_ name: String, _ value: String) -> SecretSources.Note? {
        guard case .row(_, _, let note, _) = classify(name, value) else { return nil }
        return note
    }

    private static func notKey(_ name: String, _ value: String) -> SecretSources.NotKeyReason? {
        guard case .notKey(let reason) = classify(name, value) else { return nil }
        return reason
    }

    // MARK: Which values look like keys

    @Test func keysByShapeOrNameStartTicked() {
        #expect(Self.ticked("OPENAI_API_KEY", F.openAI))
        #expect(Self.ticked("WHATEVER", F.pinecone))
        #expect(Self.ticked("DB_PASSWORD", "correct horse battery"))
        guard case .row(let kind, _, _, _) = Self.classify("OPENAI_API_KEY", F.openAI) else {
            Issue.record("no row")
            return
        }
        #expect(kind == "OpenAI key")
        // A key the masking patterns don't know is named by the provider its head names.
        guard case .row(let stripe, _, _, _) = Self.classify("STRIPE_SECRET_KEY", F.stripeSecret) else {
            Issue.record("no row")
            return
        }
        #expect(stripe == "Stripe key")
    }

    @Test func settingsAreCountedNotListed() {
        let settings: [(String, String)] = [
            ("CHUNK_SIZE", "800"), ("DEBUG", "true"), ("FEATURE", "off"), ("OPENAI_MODEL", "gpt-5"),
            ("LANGSMITH_ENDPOINT", "https://api.smith.langchain.com"), ("REDIS_HOST", "cache.internal"),
            ("NEXT_PUBLIC_SUPABASE_URL", "https://abcdefghijklmnop.supabase.co"), ("AWS_REGION", "us-east-1"),
            ("DB_PORT", "5432"), ("NODE_ENV", "development"),
        ]
        for (name, value) in settings {
            #expect(Self.notKey(name, value) == .setting, "\(name)")
        }
        #expect(Self.classify("EMPTY", "  ") == .none)
    }

    @Test func aURLWithAPasswordOrARandomPathIsStillAKey() {
        #expect(Self.ticked("DATABASE_URL", "postgres://rag:Tr0ub4dor3horse@db/rag"))
        let webhook = "https://hooks.example.invalid/services/T0A1B2C3D/B4E5F6G7H/Xy7Kq2Lm9Np4Rs8Tv3Wx6Yz1"
        #expect(Self.classify("SLACK_WEBHOOK_URL", webhook) != .notKey(.setting))
        // A number under a secret's name is a PIN, not a setting.
        #expect(Self.ticked("DB_PASSWORD", "84726193"))
    }

    @Test func placeholdersAreNotKeys() {
        let values = ["your-api-key-here", "<your key>", "YOUR_OPENAI_KEY", "changeme", "change_me", "replace_me",
                      "REPLACE-ME", "xxx", "sk-" + "proj-xxxxxxxxxxxxxxxxxxxx", "sk-" + "…", "pk_" + "test_..."]
        for value in values {
            #expect(Self.notKey("OPENAI_API_KEY", value) == .placeholder, "\(value)")
        }
        // A random value that happens to hold three x's is still a key.
        #expect(Self.ticked("API_KEY", "Qm4Rt8xxxVx2Bn6Lp9Zc3Hd7Kf1"))
    }

    // MARK: References and encrypted values

    @Test func referencesAreSkippedAndEncryptedValuesRefused() {
        #expect(Self.notKey("OPENAI_API_KEY", "${{ secrets.OPENAI }}") == .reference)
        #expect(Self.notKey("OPENAI_API_KEY", "op://dev/openai/credential") == .reference)
        #expect(Self.notKey("OPENAI_API_KEY", "${OPENAI_KEY_PROD}") == .builtFrom(["OPENAI_KEY_PROD"]))
        #expect(Self.notKey("DATABASE_URL", "postgres://rag:${DB_PASS}@db/rag") == .builtFrom(["DB_PASS"]))
        #expect(SecretSources.NotKeyReason.builtFrom(["DB_PASS"]).sentence == "Built from DB_PASS")
        let sops = "ENC[AES256_GCM,data:Zm9vYmFy,iv:bWFkZS11cA==,tag:dGFnLXRhZw==,type:str]"
        let dotenvx = "encrypted:" + "BHLTq2Lm9Np4Rs8Tv3Wx6Yz1Ab5Cd7Ef9Gh2Jk4Lm6Np8Qr0St"
        guard case .row(_, let sopsTicked, _, let sopsRefusal) = Self.classify("API_KEY", sops),
              case .row(_, let dotenvxTicked, _, let dotenvxRefusal) = Self.classify("API_KEY", dotenvx) else {
            Issue.record("encrypted values are listed")
            return
        }
        #expect(!sopsTicked && sopsRefusal == .encryptedSops)
        #expect(!dotenvxTicked && dotenvxRefusal == .encryptedDotenvx)
        // A key with a reference inside it would be stored as written: listed, with why it can't be.
        guard case .row(_, _, _, let mixed) = Self.classify("API_KEY", "Zq8Lm2Np7Rt4Vx9Bc3Df6Gh/${SUFFIX}") else {
            Issue.record("a key beside a reference is listed")
            return
        }
        #expect(mixed == .reference(["SUFFIX"]))
    }

    @Test func valuesSecretsCantKeepAreRefused() {
        let pem = F.privateKeyHead + "\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASC\n" + F.privateKeyTail
        guard case .row(_, let ticked, _, let refusal) = Self.classify("PRIVATE_KEY", pem) else {
            Issue.record("a private key is listed")
            return
        }
        #expect(!ticked && refusal == .lineBreaks)
        let long = "Zq8Lm2Np7Rt4Vx9B" + String(repeating: "c3Df6Gh1", count: 2_100)
        guard case .row(_, _, _, let tooLong) = Self.classify("API_KEY", long) else {
            Issue.record("a long key is listed")
            return
        }
        #expect(tooLong == .tooLong)
        guard case .row(_, _, _, let nul) = Self.classify("API_KEY", "Zq8Lm2Np7Rt4\u{0}Vx9Bc3Df6Gh") else {
            Issue.record("a key with a NUL is listed")
            return
        }
        #expect(nul == .nul)
    }

    // MARK: Notes that leave a row unticked

    @Test func publishableShortLivedAndPublicNamesStartUnticked() {
        #expect(Self.note("NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY", F.stripePublishable) == .publishable)
        #expect(Self.note("STRIPE_KEY", F.stripePublishable) == .publishable)
        #expect(Self.note("SUPABASE_KEY", "sb_" + "publishable_" + "Kp3Xw9Lm2Qr7Tv4Zn8Bc1D") == .publishable)
        let publicKey = "03f8a1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2"
        #expect(Self.note("DOTENV_PUBLIC_KEY", publicKey) == .publishable)
        #expect(Self.note("AWS_SESSION_TOKEN", "IQoJb3JpZ2luX2VjEHoaCXVzLWVhc3QtMSJHMEUCIQD7mAdeUp") == .shortLived)
        #expect(Self.note("AWS_ACCESS_KEY_ID", "ASIA" + "Q4RT8VX2BN6LP9ZC") == .shortLived)
        #expect(Self.note("SLACK_TOKEN", "xoxe." + "xoxp-1-Mi0yLTEyMzQ1Njc4OTAtMTIzNDU2Nzg5MA") == .shortLived)
        #expect(Self.note("VERCEL_OIDC_TOKEN", F.jwt(expires: Self.now.addingTimeInterval(400 * 86_400))) == .shortLived)
        let shipped = F.jwt(expires: Self.now.addingTimeInterval(400 * 86_400))
        #expect(Self.note("NEXT_PUBLIC_SUPABASE_ANON_KEY", shipped) == .shipsToBrowsers)
        #expect(Self.note("VITE_MAPS_API_KEY", "Mq4Rt8Vx2Bn6Lp9Zc3Hd7Kf1Wj") == .shipsToBrowsers)
        #expect(Self.note("VITE_MAPS_SECRET", "mapsecretwithoutdigitsatall") == .publicName)
        for name in ["NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY", "AWS_SESSION_TOKEN", "VITE_MAPS_API_KEY"] {
            #expect(!Self.ticked(name, F.stripePublishable), "\(name)")
        }
        #expect(SecretSources.Note.publishable.sentence == "Safe to expose; usually not worth storing")
        #expect(SecretSources.Note.shortLived.sentence == "Expires within hours")
        #expect(SecretSources.Note.shipsToBrowsers.sentence == "This name ships the value to browsers.")
    }

    @Test func aTokensExpiryIsReadOnTheMac() {
        let hourAgo = F.jwt(expires: Self.now.addingTimeInterval(-3600))
        let inHours = F.jwt(expires: Self.now.addingTimeInterval(5 * 3600))
        let nextYear = F.jwt(expires: Self.now.addingTimeInterval(365 * 86_400))
        #expect(SecretSources.jwtExpiry(hourAgo) == Self.now.addingTimeInterval(-3600))
        #expect(Self.note("SERVICE_API_KEY", hourAgo) == .expired)
        #expect(!Self.ticked("SERVICE_API_KEY", hourAgo))
        #expect(Self.note("SERVICE_API_KEY", inHours) == .shortLived)
        #expect(Self.ticked("SERVICE_API_KEY", nextYear))
        // Only a key's name ticks a token: any web token has this shape.
        #expect(!Self.ticked("SESSION_ID", nextYear))
        // A token that doesn't decode is not called expired.
        #expect(SecretSources.jwtExpiry("eyJhbGciOi.not-base64!.c2lnbmF0dXJl") == nil)
        #expect(SecretSources.jwtExpiry("eyJ" + F.base64URL("{}") + "." + F.base64URL(#"{"exp":"soon"}"#) + ".c2ln") == nil)
    }

    @Test func theSourceCanSayItIsSecret() {
        guard case .row(let kind, let ticked, _, _) = Self.classify("NOTE_FIELD", "plain words", sourceSays: true) else {
            Issue.record("a value its source calls secret is listed")
            return
        }
        #expect(ticked && kind == "a secret, by its source")
        #expect(Self.classify("NOTE_FIELD", "your-key-here", sourceSays: true) == .notKey(.placeholder))
    }

    // MARK: Names

    @Test func namesFromPartsSplitCamelCase() {
        #expect(StoredSecretName.fromParts(["openai", "apiKey"]) == "OPENAI_API_KEY")
        #expect(StoredSecretName.fromParts(["db", "password"]) == "DB_PASSWORD")
        #expect(StoredSecretName.fromParts(["OpenAI", "ApiKey"]) == "OPENAI_API_KEY")
        #expect(StoredSecretName.fromParts(["GitHub", "token"]) == "GITHUB_TOKEN")
        #expect(StoredSecretName.fromParts(["ConnectionStrings", "Default"]) == "CONNECTION_STRINGS_DEFAULT")
        #expect(StoredSecretName.fromParts(["2fa", "secret"]) == "KEY_2FA_SECRET")
        #expect(StoredSecretName.fromParts([]) == "KEY")
        // The existing suggestion is unchanged: the MCP-config import names its keys as before.
        #expect(StoredSecretName.suggested(from: "apiKey") == "APIKEY")
    }

    @Test func thePurposeNamesTheFileAndItsFolder() {
        #expect(SecretSources.purpose(file: ".env", folder: "rag-api") == "From .env in rag-api")
        #expect(SecretSources.purpose(file: "secrets.json", folder: nil) == "From secrets.json")
        let long = SecretSources.purpose(file: String(repeating: "a", count: 300), folder: "x")
        #expect(long.count <= SecretVault.maxPurposeLength)
    }
}
