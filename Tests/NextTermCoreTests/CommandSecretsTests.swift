import Foundation
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
        ("vault login s.abc123", "vault login •••"),
        ("vault login hvs.CAESIJmadeuptokenvalue", "vault login •••"),
        ("gh secret set X --body v", "gh secret set X --body •••"),
        ("gh secret set X -b v", "gh secret set X -b •••"),
        ("htpasswd -b f u pw", "htpasswd -b f u •••"),
        ("htpasswd -bc .htpasswd admin s3cret", "htpasswd -bc .htpasswd admin •••"),
        ("DB_PASSWORD='$ecret1' x", "DB_PASSWORD=••• x"),
        ("redis-cli -u redis://:pw@h", "redis-cli -u redis://:•••@h"),
        // Continued onto the next line with a backslash.
        ("mysql -u root \\\n  -pS3cret db", "mysql -u root \\\n  -p••• db"),
        ("curl https://h \\\n  -u me:s3cret", "curl https://h \\\n  -u me:•••"),
        ("app --password \\\n  s3cret", "app --password \\\n  •••"),
        ("sshpass \\\n  -p s3cret ssh h", "sshpass \\\n  -p ••• ssh h"),
        ("docker login \\\n  -u me -p s3cret", "docker login \\\n  -u me -p •••"),
        ("redis-cli \\\n  -a s3cret ping", "redis-cli \\\n  -a ••• ping"),
        ("echo s3cret | \\\n  sudo -S whoami", "echo ••• | \\\n  sudo -S whoami"),
        ("sudo -S x <<< \\\n s3cret", "sudo -S x <<< \\\n •••"),
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

    @Test func linesWithSecretsAreDroppedAndMasked() {
        for (line, masked) in Self.dropped {
            #expect(!CommandSecrets.mayKeep(line), "\(line)")
            #expect(CommandSecrets.mask(line) == masked, "\(line)")
        }
    }

    @Test func aLineStartingWithASpaceIsDropped() {
        #expect(!CommandSecrets.mayKeep(" ls"))
        #expect(CommandSecrets.mayKeep("ls"))
    }

    /// A line holding a line break is never put back as it was typed.
    @Test func aLineThatGoesOnToAnotherIsDropped() {
        #expect(!CommandSecrets.mayKeep("ls \\\n  -la"))
        #expect(!CommandSecrets.mayKeep("ls\r"))
        #expect(!CommandSecrets.mayKeep("ls \\\r\n  -la"))
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
            // The token after vault's options; gh's body; htpasswd's last word.
            ("vault login -no-print s.abc123", "vault login -no-print •••"),
            ("vault login -method token s.abc123", "vault login -method token •••"),
            ("gh secret set X --body=v", "gh secret set X --body=•••"),
            ("gh secret set X -bv", "gh secret set X -b•••"),
            ("htpasswd -nb admin s3cret > .htpasswd", "htpasswd -nb admin ••• > .htpasswd"),
            ("htpasswd -B -b f u s3cret && nginx -s reload", "htpasswd -B -b f u ••• && nginx -s reload"),
            // In single quotes $ is a letter like any other.
            ("DB_PASSWORD='$ecretPa55' npm start", "DB_PASSWORD=••• npm start"),
            ("mysql --password='$uperS3cret'", "mysql --password=•••"),
            ("mysql -p'$uperS3cret'", "mysql -p•••"),
            ("sshpass -p '$x9' ssh h", "sshpass -p ••• ssh h"),
            ("redis-cli -a '$ecret' ping", "redis-cli -a ••• ping"),
            ("echo '$ecret' | sudo -S x", "echo ••• | sudo -S x"),
            // A URL's password with no user before it, or an @ in it.
            ("REDIS_URL=redis://:s3cretpw@cache.internal:6379 npm start", "REDIS_URL=redis://:•••@cache.internal:6379 npm start"),
            ("celery -A app worker -b rediss://:s3cretpw@h:6380/0", "celery -A app worker -b rediss://:•••@h:6380/0"),
            ("git clone https://me:p@ssw0rd@h/r", "git clone https://me:•••@h/r"),
            ("git clone https://glpat-abcdefghij1234567890@gitlab.com/o/r", "git clone https://•••@gitlab.com/o/r"),
            // Masked already is only the mask itself.
            ("DB_PASSWORD=hunter2••• npm start", "DB_PASSWORD=••• npm start"),
            ("mysql --password hunter2•••", "mysql --password •••"),
            // A key name that says what it is, or a value that looks like a key.
            ("AWS_SECRET_ACCESS_KEY=abc x", "AWS_SECRET_ACCESS_KEY=••• x"),
            ("APP_SIGNING_KEY=abc x", "APP_SIGNING_KEY=••• x"),
            ("STRIPE_KEY=sk_test_Zx8Kq2Lm9Pw4Rt7Yb3 npm start", "STRIPE_KEY=••• npm start"),
            ("SECRETKEY=abc x", "SECRETKEY=••• x"),
            ("DB_PW=abc x", "DB_PW=••• x"),
            ("PASSWORD2=abc x", "PASSWORD2=••• x"),
            // Fed on stdin, and the other tools that take a password inline.
            ("echo s3cret | docker login -u me --password-stdin", "echo ••• | docker login -u me --password-stdin"),
            ("docker login -u me --password-stdin <<< s3cret", "docker login -u me --password-stdin <<< •••"),
            (#"curl -H "X-Vault-Token: s.abc123" https://h"#, #"curl -H "X-Vault-Token: •••" https://h"#),
            (#"curl --cookie "session=abc123" https://h"#, "curl --cookie ••• https://h"),
            (#"curl -b "sid=abc123" https://h"#, "curl -b ••• https://h"),
            ("curl --oauth2-bearer abc123 https://h", "curl --oauth2-bearer ••• https://h"),
            ("mongosh -u admin -p s3cret", "mongosh -u admin -p •••"),
            ("openssl enc -aes-256-cbc -k s3cret", "openssl enc -aes-256-cbc -k •••"),
            ("zip -P s3cret a.zip f", "zip -P ••• a.zip f"),
            ("7z a -pS3cret a.7z f", "7z a -p••• a.7z f"),
            ("security add-generic-password -a me -s svc -w s3cret", "security add-generic-password -a me -s svc -w •••"),
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
            "app --token-file=t.txt",
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
            // Branches named for their ticket.
            "git checkout -b ABC-1234-fix-login-redirect-for-v2",
            "git push -u origin PROJ-123-add-user-settings-page-2fa",
            "git checkout feat/PROJ-1234-AddUserSettingsPage",
            "git rebase origin/JIRA-4521-migrate-auth0-to-cognito",
            "git checkout -b task-1234-fix-login-redirect",
            // Where a secret comes from, not the secret.
            "docker build --secret id=npmrc,src=.npmrc .",
            #"curl -H "Authorization: Bearer $TOKEN" https://h"#,
            #"git -c http.extraHeader="Authorization: Bearer $TOKEN" clone https://h/r"#,
            #"curl -u "$USER:$PASS" https://h"#,
            "REDIS_URL=redis://:$REDIS_PASSWORD@h npm start",
            #"echo "$CR_PAT" | docker login ghcr.io -u me --password-stdin"#,
            #"echo -n "$PW" | sudo -S whoami"#,
            #"gh secret set X --body "$VALUE""#,
            "gh secret set X < secret.txt",
            "curl -b cookies.txt https://h",
            "security find-generic-password -s svc -w",
            // A quote that ends the string the name sits in.
            #"grep -rn "api_key=" src"#,
            "rg 'token=' src",
            #"git log -S "password=""#,
            // Another command's -p, after the one that takes a password.
            "mysql -u root db < dump.sql && cp -pR a b",
            "mysqldump db > d.sql && ssh -p2222 h",
            "sshpass -e ssh -p 2222 me@h",
            "docker login -u me --password-stdin < t.txt && docker run -p 8080:80 img",
            // Keys that are not secrets.
            "CACHE_KEY=v2 npm test",
            "SSH_KEY=~/.ssh/id_ed25519 ./deploy.sh",
            "PRIMARY_KEY=id rake db:migrate",
            #"git commit -m "rename SORT_KEY=...""#,
            // Asking for the password, or not taking one.
            "vault login",
            "vault login -method=userpass username=me",
            "vault login -method github",
            "htpasswd -c .htpasswd admin",
            "zip -r a.zip f",
        ]
        for line in lines {
            #expect(CommandSecrets.mayKeep(line), "\(line) -> \(CommandSecrets.mask(line))")
        }
    }

    @Test func aKeyInsideAPathIsStillMasked() {
        let line = "curl https://h/api/v1/tokens/4fJk2Lq9ZxWv7Rt3Yh8Np1Bm6Cd0Es5Gu"
        #expect(CommandSecrets.mask(line) == "curl https://h/api/v1/tokens/•••")
        #expect(CommandSecrets.mask("blob 4fJk2Lq9ZxWv7Rt3Yh8Np1Bm6Cd0Es5Gu") == "blob •••")
        #expect(CommandSecrets.mask("blob 4fJk2Lq9-ZxWv7Rt3_Yh8Np1Bm6Cd0Es5Gu") == "blob •••")
    }

    @Test func maskingStaysOnItsRow() {
        let text = "x@mac app % app --token\nok\nx@mac app % DB_PASSWORD=x npm start\nlistening on 3000"
        let masked = CommandSecrets.mask(text)
        #expect(masked == "x@mac app % app --token\nok\nx@mac app % DB_PASSWORD=••• npm start\nlistening on 3000")
    }

    /// A value cut at a quote the line never closes ends there: the quote and the rest of the row stay.
    @Test func aQuoteThatClosesTheStringAroundAValueStays() {
        #expect(CommandSecrets.mask(#"msg="set token=abc" user=me"#) == #"msg="set token=•••" user=me"#)
        #expect(CommandSecrets.mask(#"log "api_key=abc" src"#) == #"log "api_key=•••" src"#)
        #expect(CommandSecrets.mask(#"DB_PASSWORD="hunter2 and more"#) == "DB_PASSWORD=•••")
    }

    @Test func maskingTwiceChangesNothingMore() {
        for (line, masked) in Self.dropped {
            #expect(CommandSecrets.mask(masked) == masked, "\(line)")
        }
    }

    /// ICU gives up on a run of a few hundred thousand characters, and would miss what follows it: a line
    /// it gives up on is masked whole, and the lines around it as usual. (A reader stands in for ICU here:
    /// a real give-up holds tens of megabytes, which other suites measuring memory in parallel would see.)
    @Test func aLineTooLongToReadIsMaskedWhole() {
        let read = { (text: String) -> String? in text.contains("LONG") ? nil : CommandSecrets.masked(text) }
        let text = "DB_PASSWORD=x npm start\nLONG DB_PASSWORD=x\nls \\\nLONG\nls"
        #expect(CommandSecrets.mask(text, reading: read) == "DB_PASSWORD=••• npm start\n•••\n•••\n•••\nls")
        #expect(CommandSecrets.mask("LONG DB_PASSWORD=x", reading: read) == "•••")
        #expect(CommandSecrets.mask("DB_PASSWORD=x", reading: read) == "DB_PASSWORD=•••")
    }

    /// Bytes printed into a tab are anyone's: a crafted row is read in one pass, so masking a long one
    /// takes no longer than its length.
    @Test func aCraftedRowIsMaskedInOnePass() {
        let pieces = [
            "a-token-", " --token-", "token_", "eyJ", "password", "a.", "a-", "mysql ", "curl -u ", "\"a: ",
            "\"Authorization: ", "echo a ", "x://a:", "token=", "htpasswd -b ", "vault login -x ", "-----BEGIN A",
            "a\n", " \n", "\\\n", "\"",
        ]
        let clock = ContinuousClock()
        for piece in pieces {
            let row = String(repeating: piece, count: 20_000 / piece.count)
            let elapsed = clock.measure { _ = CommandSecrets.mask(row) }
            #expect(elapsed < .seconds(1), "\(piece): \(elapsed)")
        }
    }
}
