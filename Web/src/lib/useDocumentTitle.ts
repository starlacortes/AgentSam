import { useEffect } from 'react'

/** Names the browser tab after the page, e.g. "● Running · Plan a trip — AgentSam". */
export function useDocumentTitle(title: string | null | undefined): void {
  useEffect(() => {
    document.title = title ? `${title} — AgentSam` : 'AgentSam'
  }, [title])
}
