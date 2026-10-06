type ArtalkWrap = HTMLElement & {
  dataset: DOMStringMap & {
    server: string
    site: string
    pageKey: string
    pageTitle: string
  }
}

declare global {
  interface Window {
    Artalk?: {
      init: (opts: Record<string, unknown>) => { destroy?: () => void }
    }
  }
}

let artalkInstance: { destroy?: () => void } | null = null
let loadingPromise: Promise<void> | null = null

function loadArtalkAssets(server: string): Promise<void> {
  if (window.Artalk) {
    return Promise.resolve()
  }
  if (loadingPromise) {
    return loadingPromise
  }

  const base = server.replace(/\/$/, "")
  loadingPromise = new Promise((resolve, reject) => {
    const cssId = "artalk-css"
    if (!document.getElementById(cssId)) {
      const link = document.createElement("link")
      link.id = cssId
      link.rel = "stylesheet"
      link.href = `${base}/dist/Artalk.css`
      document.head.appendChild(link)
    }

    const script = document.createElement("script")
    script.src = `${base}/dist/Artalk.js`
    script.async = true
    script.onload = () => resolve()
    script.onerror = () => reject(new Error("Failed to load Artalk.js"))
    document.head.appendChild(script)
  })

  return loadingPromise
}

function mountArtalk() {
  const wrap = document.querySelector(".artalk-wrap") as ArtalkWrap | null
  const container = document.getElementById("artalk-container")
  if (!wrap || !container || !window.Artalk) {
    return
  }

  if (artalkInstance?.destroy) {
    artalkInstance.destroy()
    artalkInstance = null
  }
  container.innerHTML = ""

  artalkInstance = window.Artalk.init({
    el: "#artalk-container",
    pageKey: wrap.dataset.pageKey,
    pageTitle: wrap.dataset.pageTitle,
    server: wrap.dataset.server,
    site: wrap.dataset.site,
  })
}

document.addEventListener("nav", () => {
  const wrap = document.querySelector(".artalk-wrap") as ArtalkWrap | null
  if (!wrap) {
    return
  }

  void loadArtalkAssets(wrap.dataset.server)
    .then(() => mountArtalk())
    .catch((err) => console.error(err))
})
