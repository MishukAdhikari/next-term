import Testing
@testable import NextTermCore

@Suite struct CommandSecretsTests {
    /// Lines that may not be saved, and what masking leaves of each.
    static let dropped: [(line: String, masked: String)] = [
        ("DB_PASSWORD=x npm start", "DB_PASSWORD=••• npm start"),
        ("PGPASSWORD=x psql", "PGPASSWORD=••• psql"),
        ("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuv node a.js", "OPENAI_API_KEY=••• node a.js"),
        ("mysql -pS3cret", "mysql -p•••"),
        ("sshpass -p x ssh h", "sshpass -p ••• ssh h"),
        ("curl -u user:pass https://h", "curl -u user:••• https://h"),
        (#"curl -H "Authorization: Bearer abc""#, #"curl -H "Authorization: •••""#),
        ("psql postgres://u:p@h/db", "psql postgres://u:•••@h/db"),
        ("export GITHUB_TOKEN=made-up-token-value", "export GITHUB_TOKEN=•••"),
        ("echo pw | sudo -S x", "echo ••• | sudo -S x"),
    ]

    static let kept = [
        "git checkout 3f786850e387550fdab836ed7e6dc881de23001b",
        "cd /Users/x/Code/app/Sources/NextTerm",
        "npm run dev",
        "claude --resume 123e4567-e89b-12d3-a456-426614174000",
        "mkdir -p a/b",
        "cp -pR a b",
        "git log -p",
        "ssh -p 2222 h",
        "docker run -p 8080:80 i",
    ]

    /// zsh's default prompt, a ❯ prompt and bash's.
    static let prompts = ["x@mac app % ", "app ❯ ", "x@mac:~/app$ "]

    @Test func linesWithSecretsAreDropped() {
        for (line, _) in Self.dropped {
            #expect(!CommandSecrets.mayKeep(line), "\(line)")
        }
    }

    @Test func aLineStartingWithASpaceIsDropped() {
        #expect(!CommandSecrets.mayKeep(" ls"))
        #expect(CommandSecrets.mayKeep("ls"))
    }

    @Test func ordinaryLinesAreKept() {
        for line in Self.kept {
            #expect(CommandSecrets.mayKeep(line), "\(line)")
            #expect(CommandSecrets.mask(line) == line, "\(line)")
        }
    }

    /// A dropped line echoed after a prompt (in scrollback) has only its secret masked. The leading-space
    /// case is left out: it holds no secret, and its echo is blanked by whoever drops it.
    @Test func aSecretAfterAPromptIsMaskedAndTheRestOfTheLineStays() {
        for prompt in Self.prompts {
            for (line, masked) in Self.dropped {
                #expect(CommandSecrets.mask(prompt + line) == prompt + masked, "\(prompt + line)")
            }
            for line in Self.kept {
                #expect(CommandSecrets.mask(prompt + line) == prompt + line, "\(prompt + line)")
            }
        }
    }

    @Test func theOtherShapesOfASecretAreDroppedAndMasked() {
        let cases: [(line: String, masked: String)] = [
            ("MYSQL_PWD=x mysql", "MYSQL_PWD=••• mysql"),
            ("docker run -e DB_PASSWORD=x img", "docker run -e DB_PASSWORD=••• img"),
            ("java -Ddb.password=x -jar app.jar", "java -Ddb.password=••• -jar app.jar"),
            ("mysql --password=S3cret", "mysql --password=•••"),
            ("gh auth login --token abc", "gh auth login --token •••"),
            ("app --api-key abc --secret 'two words'", "app --api-key ••• --secret •••"),
            ("aws-tool --secret-key abc", "aws-tool --secret-key •••"),
            ("mysqldump -uroot -pS3cret db", "mysqldump -uroot -p••• db"),
            ("mariadb -pS3cret", "mariadb -p•••"),
            ("redis-cli -a s3cret ping", "redis-cli -a ••• ping"),
            ("docker login -u me -p s3cret", "docker login -u me -p •••"),
            ("curl --user me:s3cret https://h", "curl --user me:••• https://h"),
            (#"curl -u "me:two words" https://h"#, #"curl -u "me:•••" https://h"#),
            ("openssl rsa -in k.pem -passin pass:s3cret", "openssl rsa -in k.pem -passin pass:•••"),
            ("openssl enc -aes256 -pass pass:s3cret", "openssl enc -aes256 -pass pass:•••"),
            ("curl -H 'Cookie: sid=abc; theme=dark' https://h", "curl -H 'Cookie: •••' https://h"),
            (#"curl -H "X-Api-Key: abc" https://h"#, #"curl -H "X-Api-Key: •••" https://h"#),
            (#"git -c http.extraHeader="Authorization: Basic abc" clone https://h/r"#, "git -c http.extraHeader=••• clone https://h/r"),
            ("sudo -S cmd <<< pw", "sudo -S cmd <<< •••"),
            ("curl https://curl.se -u me:s3cret", "curl https://curl.se -u me:•••"),
            ("curl -u me -U proxy:s3cret https://h", "curl -u me -U proxy:••• https://h"),
            ("curl 'https://h/cb?code=1&access_token=abc'", "curl 'https://h/cb?code=1&access_token=•••'"),
        ]
        for (line, masked) in cases {
            #expect(!CommandSecrets.mayKeep(line), "\(line)")
            #expect(CommandSecrets.mask(line) == masked, "\(line)")
        }
    }

    @Test func lookalikesAreKept() {
        let lines = [
            "TOKENIZERS_PARALLELISM=false python train.py",
            "llm --max-tokens 100 hi",
            "docker login --password-stdin -u me",
            "gh auth login --with-token < token.txt",
            "app --token-file t.txt",
            "psql --no-password -h db",
            "mysql -u root -p mydb",
            "mysql -P 3306 -h db",
            "curl -u me https://h",
            "curl --user-agent x https://h",
            "echo hi | sudo tee /etc/x",
            "openssl rsa -in k.pem -passin env:KEY_PASS",
            "API_TOKEN=$API_TOKEN ./deploy.sh",
            #"deploy --token "${DEPLOY_TOKEN}""#,
            "cd /Users/x/Code/Project2024/Sources/Module1",
        ]
        for line in lines {
            #expect(CommandSecrets.mayKeep(line), "\(line) -> \(CommandSecrets.mask(line))")
        }
    }

    @Test func aKeyInsideAPathIsStillMasked() {
        let line = "curl https://h/api/v1/tokens/4fJk2Lq9ZxWv7Rt3Yh8Np1Bm6Cd0Es5Gu"
        #expect(CommandSecrets.mask(line) == "curl https://h/api/v1/tokens/•••")
        #expect(CommandSecrets.mask("blob 4fJk2Lq9ZxWv7Rt3Yh8Np1Bm6Cd0Es5Gu") == "blob •••")
    }

    @Test func maskingStaysOnItsRow() {
        let text = "x@mac app % app --token\nok\nx@mac app % DB_PASSWORD=x npm start\nlistening on 3000"
        let masked = CommandSecrets.mask(text)
        #expect(masked == "x@mac app % app --token\nok\nx@mac app % DB_PASSWORD=••• npm start\nlistening on 3000")
    }
}
