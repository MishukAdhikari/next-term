import Foundation
@testable import NextTermCore

/// Files of keys for the import's tests: made-up projects and made-up values. Each value is a provider's head and
/// filler, put together at run time, so no file here holds a key-shaped string whole.
enum SecretSourcesFixtures {
    static let openAI = "sk-" + "proj-" + "Qm4Rt8Vx2Bn6Lp9Zc3Hd7Kf1Wj5Ys0Ea"
    static let openAIOld = "sk-" + "proj-" + "Hd7Kf1Wj5Ys0EaQm4Rt8Vx2Bn6Lp9Zc3"
    static let pinecone = "pcsk_" + "4Fh8Jk2Lm6Np0Qr4St8Vw2Xy6Za0Bc4De8"
    static let langSmith = "lsv2_" + "pt_" + "8c1e5a9d3f7b2e6a0c4d8f2b6e0a4c8d_5f1a9c3e7b"
    static let stripeSecret = "sk_" + "test_" + "51Mx3Nq7Rv2Tz8Wb4Yc6Ad9Ef1Gh5Jk"
    static let stripePublishable = "pk_" + "test_" + "51Mx3Nq7Rv2Tz8Wb4Yc6Ad9Ef1Gh5Jm"
    static let supabaseSecret = "sb_" + "secret_" + "Kp3Xw9Lm2Qr7Tv4Zn8Bc1Df6Gh"
    static let privateKeyHead = "-----BEGIN " + "PRIVATE KEY-----"
    static let privateKeyTail = "-----END " + "PRIVATE KEY-----"

    /// A JSON web token whose `exp` is `expires`, with a made-up subject and signature.
    static func jwt(expires: Date) -> String {
        let header = base64URL(#"{"alg":"HS256","typ":"JWT"}"#)
        let seconds = Int(expires.timeIntervalSince1970)
        let payload = base64URL(#"{"sub":"made-up-subject","exp":"# + String(seconds) + "}")
        return header + "." + payload + "." + "Zm9vYmFyYmF6cXV4LW1hZGUtdXA"
    }

    static func base64URL(_ text: String) -> String {
        let plain = Data(text.utf8).base64EncodedString()
        let url = plain.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return url.replacingOccurrences(of: "=", with: "")
    }

    /// A Python RAG service's `.env`: three keys and four values that aren't keys.
    static let ragAPIEnv = """
        # rag-api, made up for a test
        OPENAI_API_KEY=\(openAI)
        PINECONE_API_KEY=\(pinecone)
        LANGSMITH_API_KEY=\(langSmith)
        LANGSMITH_ENDPOINT=https://api.smith.langchain.com
        OPENAI_MODEL=gpt-5
        CHUNK_SIZE=800
        DATABASE_URL=postgres://rag:${DB_PASS}@db/rag

        """

    /// A Next.js app's `.env.local` as `vercel env pull` writes it, with `OPENAI_API_KEY` on lines 4 and 19.
    static func shopWebEnv(now: Date) -> String {
        let oidc = jwt(expires: now.addingTimeInterval(12 * 3600))
        return """
            # Created by Vercel CLI
            STRIPE_SECRET_KEY="\(stripeSecret)"
            NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY="\(stripePublishable)"
            OPENAI_API_KEY="\(openAIOld)"
            NEXT_PUBLIC_SUPABASE_URL="https://abcdefghijklmnop.supabase.co"
            SUPABASE_SECRET_KEY="\(supabaseSecret)"
            VERCEL_OIDC_TOKEN="\(oidc)"
            NODE_ENV="development"
            VERCEL="1"
            VERCEL_ENV="development"
            VERCEL_URL=""
            TURBO_CACHE="remote:rw"

            # the newer key
            NX_DAEMON="false"
            VERCEL_TARGET_ENV="development"
            VERCEL_GIT_PROVIDER=""
            VERCEL_GIT_REPO_SLUG=""
            OPENAI_API_KEY="\(openAIOld.reversedText)"

            """
    }

    /// Flat, as `doppler secrets download --format json` writes it.
    static let dopplerJSON = """
        {
          "CHUNK_SIZE": "800",
          "DOPPLER_CONFIG": "dev",
          "DOPPLER_ENVIRONMENT": "dev",
          "DOPPLER_PROJECT": "rag-api",
          "OPENAI_API_KEY": "\(openAI)",
          "PINECONE_API_KEY": "\(pinecone)"
        }
        """

    /// Nested, as an `appsettings.json` holds its settings, with a comment.
    static let appSettingsJSON = """
        {
          // made up for a test
          "Logging": { "LogLevel": { "Default": "Information" } },
          "OpenAI": { "ApiKey": "\(openAI)", "Model": "gpt-5" },
          "ConnectionStrings": { "Default": "Server=db;Database=shop;Trusted_Connection=True;" },
          "AllowedHosts": "*",
        }
        """

    /// An ECS task definition: a name/value `environment` and a `secrets` entry that only points at a parameter.
    static let ecsTaskJSON = """
        {
          "family": "rag-api",
          "containerDefinitions": [
            {
              "name": "api",
              "image": "example.invalid/rag-api:1.4",
              "environment": [
                {"name": "OPENAI_API_KEY", "value": "\(openAI)"},
                {"name": "LOG_LEVEL", "value": "info"}
              ],
              "secrets": [
                {"name": "PINECONE_API_KEY", "valueFrom": "arn:aws:ssm:us-east-1:000000000000:parameter/made-up"}
              ]
            }
          ]
        }
        """

    /// A Google Cloud service-account key: one whole credential file.
    static var serviceAccountJSON: String {
        let key = privateKeyHead + "\\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7made0up\\n" + privateKeyTail + "\\n"
        return """
            {
              "type": "service_account",
              "project_id": "made-up-project",
              "private_key_id": "0123456789abcdef0123456789abcdef01234567",
              "private_key": "\(key)",
              "client_email": "importer@made-up-project.iam.gserviceaccount.com",
              "client_id": "000000000000000000000",
              "token_uri": "https://oauth2.googleapis.com/token"
            }
            """
    }

    /// The bytes of a text, for `SecretSources.read`, which wipes them.
    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// The report a text gives as a file of this name.
    static func report(_ text: String, name: String, folder: String? = nil, stored: Set<String> = [],
                       now: Date = Date()) -> SourceReport {
        var data: [UInt8] = bytes(text)
        return SecretSources.read(&data, name: name, folder: folder, stored: stored, now: now)
    }
}

extension String {
    /// The characters in the other order: a second made-up value of the same shape's tail.
    var reversedText: String {
        let head = String(prefix(8))
        return head + String(dropFirst(8).reversed())
    }
}
