// Voice setup models, mirroring VoiceRoutes.swift and Speech.swift.

export interface VoiceEngine {
  providerID: string
  providerName: string
  model: string
  voice?: string
}

export interface VoiceSettings {
  sttProviderID?: string
  sttModel?: string
  ttsProviderID?: string
  ttsModel?: string
  ttsVoice?: string
}

export interface VoiceInfo {
  setup: { stt?: VoiceEngine; tts?: VoiceEngine }
  settings: VoiceSettings
  providers: { id: string; name: string; canTranscribe: boolean; canSpeak: boolean }[]
  voices: string[]
}
