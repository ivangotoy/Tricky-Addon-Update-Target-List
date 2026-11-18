import { marked } from 'marked'
import type { Cli } from '../cli'
import './markdown.scss'

// changelog and guide come from the network: raw HTML in them is shown as text, not run in the root WebUI
const escapeHtml = (s: string) => s.replace(/[&<>"']/g, c => `&#${c.charCodeAt(0)};`)
marked.use({ renderer: { html: ({ text }) => escapeHtml(text) } })

export function parseMarkdown(text: string): string {
  return marked.parse(text) as string
}

export function renderMarkdown(text: string, target: HTMLElement, cli: Cli): void {
  target.innerHTML = parseMarkdown(text)

  target.querySelectorAll<HTMLAnchorElement>('a[href]').forEach((a) => {
    const href = a.getAttribute('href')
    if (href?.startsWith('http://') || href?.startsWith('https://')) {
      const url = href
      a.href = 'javascript:void(0)'
      a.onclick = (e) => {
        e.preventDefault()
        cli.linkRedirect(url)
      }
    } else {
      a.removeAttribute('href')
    }
  })
}
