CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
INSERT INTO ItemTable VALUES ('history.recentlyOpenedPathsList', '{"entries":[{"folderUri":"file://HOME/Code/api"},{"folderUri":"file://HOME/Code/web"},{"folderUri":"vscode-remote://ssh-remote+box/srv/app"}]}');
INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'eyJhbGciOiJIUzI1NiJ9.eyJmaXh0dXJlIjoic2VjcmV0In0.bm90LWEtcmVhbC1zaWduYXR1cmU');
INSERT INTO ItemTable VALUES ('cursorAuth/refreshToken', 'FixtureSecretAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
