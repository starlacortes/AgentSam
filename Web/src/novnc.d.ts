// The parts of noVNC's RFB client the live browser window uses. The package ships no types.
declare module '@novnc/novnc' {
  export interface RFBOptions {
    credentials?: { username?: string; password?: string; target?: string }
    shared?: boolean
    wsProtocols?: string[]
  }
  export default class RFB extends EventTarget {
    constructor(target: HTMLElement, url: string, options?: RFBOptions)
    viewOnly: boolean
    scaleViewport: boolean
    resizeSession: boolean
    focusOnClick: boolean
    background: string
    disconnect(): void
    focus(): void
    blur(): void
    sendKey(keysym: number, code: string | null, down?: boolean): void
    sendCredentials(credentials: { username?: string; password?: string; target?: string }): void
  }
}
