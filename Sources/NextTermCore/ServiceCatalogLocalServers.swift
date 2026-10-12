import Foundation

// Local dev servers and dev environments, most used first. Each is named by its framework's own package or file,
// never by a port alone (8000, 3000 and 5173 are each several tools' default), and opens on the port the files give:
// the tool's config, a script's flag, a key it reads; else its documented default, which the tooltip says. The host
// is `localhost`, or `127.0.0.1` where the tool prints that.

extension ServiceCatalog {
    static let localServers: [ServiceEntry] = [vite, fastAPI, nextJS, flask, storybook, django, jupyter, astro,
                                               streamlit, nuxt, gradio, chainlit, rails, phoenixFramework, herd, ddev]

    /// A server on this Mac: named by `signals`, opened at `path` on the port `port` finds.
    static func server(_ id: String, _ name: String, rank: Int, signals: [Signal], port: LocalPort, page: String? = nil,
                       path: String = "", values: [String: KeyRole] = [:], extras: [LinkTemplate] = []) -> ServiceEntry {
        let pieces: [Piece] = path.isEmpty ? [] : [.text(path)]
        let main = LinkTemplate("app", page, .local(port), path: pieces)
        return ServiceEntry(id, name, kind: .localServer, rank: rank, place: .local, signals: signals, values: values,
                            links: [main] + extras)
    }

    // MARK: Vite, FastAPI, Next.js, Flask, Storybook

    /// Vite and the frameworks on it (SvelteKit, React Router, Remix): `server.port` in its config, `https` when
    /// `server.https` is set.
    static let vitePort = LocalPort("localhost", [.named(.vitePort), .start(["vite", "vite dev", "vite serve"])],
                                    default: 5173, httpsWhen: .viteHTTPS)
    static let vite = server("vite", "Vite", rank: 1, signals: [.dependency(.npm, "vite")], port: vitePort)

    /// Opens the interactive API docs FastAPI serves.
    static let fastAPIPort = LocalPort("localhost", [.start(["uvicorn", "fastapi dev", "fastapi run"])], default: 8000)
    static let fastAPI = server("fastapi", "FastAPI", rank: 2, signals: [.dependency(.pypi, "fastapi")],
                                port: fastAPIPort, page: "Docs", path: "/docs")

    /// Only a script's `-p`: Next.js does not read `PORT` from `.env`.
    static let nextPort = LocalPort("localhost", [.start(["next dev"])], default: 3000)
    static let nextJS = server("nextjs", "Next.js", rank: 3, signals: [.dependency(.npm, "next")], port: nextPort)

    static let flaskPort = LocalPort("127.0.0.1", [.start(["flask run"]), .env("FLASK_RUN_PORT")], default: 5000)
    static let flask = server("flask", "Flask", rank: 4, signals: [.dependency(.pypi, "flask")], port: flaskPort,
                              values: ["FLASK_RUN_PORT": .port])

    static let storybookPort = LocalPort("localhost", [.start(["storybook dev", "start-storybook"])], default: 6006)
    static let storybook = server("storybook", "Storybook", rank: 5, signals: [.dependency(.npm, "storybook")],
                                  port: storybookPort)
}

// MARK: - Django, Jupyter, Astro, Streamlit, Nuxt

extension ServiceCatalog {
    /// No setting holds Django's port: only `runserver [addr:]N` in a script.
    static let djangoPort = LocalPort("127.0.0.1", [.start(["manage.py runserver", "django-admin runserver"])],
                                      default: 8000)
    static let django = server("django", "Django", rank: 6,
                               signals: [.all([.file("manage.py", nil), .dependency(.pypi, "django")])],
                               port: djangoPort)

    /// JupyterLab, for a project with a notebook at its top. The token is never in the link: the page asks for it.
    static let jupyterPort = LocalPort("localhost", [.start(["jupyter lab", "jupyter-lab", "jupyter notebook"]),
                                                     .env("JUPYTER_PORT")], default: 8888)
    static let jupyterSignals: [Signal] = [
        .all([.any([.dependency(.pypi, "jupyterlab"), .dependency(.pypi, "notebook")]), .file("*.ipynb", nil)]),
    ]
    static let jupyter = server("jupyter", "Jupyter", rank: 7, signals: jupyterSignals, port: jupyterPort, page: "Lab",
                                path: "/lab", values: ["JUPYTER_PORT": .port])

    static let astroPort = LocalPort("localhost", [.named(.astroPort), .start(["astro dev"])], default: 4321)
    static let astro = server("astro", "Astro", rank: 8, signals: [.dependency(.npm, "astro")], port: astroPort)

    static let streamlitPort = LocalPort("localhost", [.named(.streamlitPort), .start(["streamlit run"])],
                                         default: 8501)
    static let streamlit = server("streamlit", "Streamlit", rank: 9,
                                  signals: [.dependency(.pypi, "streamlit"), .file(".streamlit/config.toml", nil)],
                                  port: streamlitPort)

    static let nuxtPort = LocalPort("localhost", [.named(.nuxtPort), .start(["nuxt dev", "nuxi dev"])], default: 3000)
    static let nuxt = server("nuxt", "Nuxt", rank: 10, signals: [.dependency(.npm, "nuxt")], port: nuxtPort)
}

// MARK: - Gradio, Chainlit, Rails, Phoenix

extension ServiceCatalog {
    /// `gradio app.py`, or `GRADIO_SERVER_PORT=N` before whatever runs the app (`python app.py`).
    static let gradioPort = LocalPort("127.0.0.1", [.start(["gradio", "GRADIO_SERVER_PORT="])], default: 7860)
    static let gradio = server("gradio", "Gradio", rank: 11, signals: [.dependency(.pypi, "gradio")], port: gradioPort)

    static let chainlitPort = LocalPort("localhost", [.start(["chainlit run"])], default: 8000)
    static let chainlitSignals: [Signal] = [
        .all([.dependency(.pypi, "chainlit"), .any([.file(".chainlit/config.toml", nil), .file("chainlit.md", nil)])]),
    ]
    static let chainlit = server("chainlit", "Chainlit", rank: 12, signals: chainlitSignals, port: chainlitPort)

    /// A script's or Procfile line's `-p`: `bin/dev` does not read `.env`.
    static let railsPort = LocalPort("localhost", [.start(["rails server", "rails s"])], default: 3000)
    static let rails = server("rails", "Rails", rank: 13, signals: [.dependency(.rubygems, "rails")], port: railsPort)

    /// Phoenix's endpoint, and its LiveDashboard in development.
    static let phoenixEndpoint = LocalPort("localhost", [.start(["mix phx.server"])], default: 4000)
    static let phoenixDashboard = LinkTemplate("dashboard", "LiveDashboard", .local(phoenixEndpoint),
                                               path: [.text("/dev/dashboard")], extra: true)
    static let phoenixFramework = server("phoenix", "Phoenix", rank: 14, signals: [.dependency(.hex, "phoenix")],
                                         port: phoenixEndpoint, extras: [phoenixDashboard])
}

// MARK: - Herd and Valet, DDEV

extension ServiceCatalog {
    /// The site Herd (or Valet) serves: `APP_URL`'s origin when its host ends `.test`, else `herd.yml`'s name, or the
    /// folder's, as `<name>.test`, `https` only when `herd.yml` says it is secured. Named `herd`, as the database
    /// row's provider is, so a project whose database row shows Herd does not list it twice.
    static let herdAppURL = OriginRule(["APP_URL"], hosts: [.suffix(".test")])
    static let herdSite = SiteRule(names: [.named(.herdName), .folderName], defaultTLD: "test", httpsWhen: .herdSecured)
    static let herdLinks: [LinkTemplate] = [
        LinkTemplate("site", "Site", .configured(herdAppURL)),
        LinkTemplate("site", "Site", .site(herdSite)),
    ]
    static let herd = ServiceEntry("herd", "Herd", kind: .localServer, rank: 15, place: .local,
                                   signals: [.origin("APP_URL", .suffix(".test")), .file("herd.yml", .local)],
                                   values: ["APP_URL": .url], links: herdLinks)

    /// `https://<name>.<project_tld>` through DDEV's router, and Mailpit on its own HTTPS port.
    static let ddevNames: [FactRef] = [.named(.ddevName), .folderName]
    static let ddevSite = SiteRule(names: ddevNames, tld: [.named(.ddevTLD)], defaultTLD: "ddev.site",
                                   port: .ddevHTTPSPort, defaultPort: 443)
    static let ddevMailpit = SiteRule(names: ddevNames, tld: [.named(.ddevTLD)], defaultTLD: "ddev.site",
                                      port: .ddevMailpitHTTPSPort, defaultPort: 8026)
    static let ddevLinks: [LinkTemplate] = [
        LinkTemplate("site", "Site", .site(ddevSite)),
        LinkTemplate("mailpit", "Mailpit", .site(ddevMailpit), extra: true),
    ]
    static let ddev = ServiceEntry("ddev", "DDEV", kind: .localServer, rank: 16, place: .local,
                                   signals: [.file(".ddev/config.yaml", .local)], links: ddevLinks)
}
