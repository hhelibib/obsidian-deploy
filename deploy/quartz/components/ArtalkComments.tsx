import { QuartzComponent, QuartzComponentConstructor, QuartzComponentProps } from "./types"
import { classNames } from "../util/lang"
// @ts-ignore
import script from "./scripts/artalk.inline"
import style from "./styles/artalk.scss"

type Options = {
  site: string
  /** Absolute URL or same-origin path, e.g. "/artalk" */
  server: string
}

export default ((opts: Options) => {
  const ArtalkComments: QuartzComponent = ({ displayClass, fileData }: QuartzComponentProps) => {
    const disableComment: boolean =
      typeof fileData.frontmatter?.comments !== "undefined" &&
      (!fileData.frontmatter?.comments || fileData.frontmatter?.comments === "false")
    if (disableComment) {
      return <></>
    }

    const pageKey = fileData.slug === "index" ? "/" : `/${fileData.slug}`
    const pageTitle = (fileData.frontmatter?.title as string | undefined) ?? pageKey

    return (
      <section
        class={classNames(displayClass, "artalk-wrap")}
        data-server={opts.server}
        data-site={opts.site}
        data-page-key={pageKey}
        data-page-title={pageTitle}
      >
        <h2>评论</h2>
        <div id="artalk-container"></div>
      </section>
    )
  }

  ArtalkComments.css = style
  ArtalkComments.afterDOMLoaded = script
  return ArtalkComments
}) satisfies QuartzComponentConstructor
