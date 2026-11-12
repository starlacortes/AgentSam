// In-app English/Spanish localization. Keys are the English source text (same convention
// as the apps' Localizable.strings), so English needs no catalog and Spanish falls back
// to the key when a translation is missing. {name} placeholders interpolate values.
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { coordinatorSpanish } from './lib/coordinator-i18n'

export type Lang = 'en' | 'es'

const STORAGE_KEY = 'agentsam.lang'

function initialLang(): Lang {
  try {
    const saved = localStorage.getItem(STORAGE_KEY)
    if (saved === 'en' || saved === 'es') return saved
  } catch {
    // Storage unavailable; fall through to the browser language.
  }
  return navigator.language.toLowerCase().startsWith('es') ? 'es' : 'en'
}

let currentLang: Lang = 'en'

/** Locale tag for date/time formatting outside React components. */
export function dateLocale(): string {
  return currentLang === 'es' ? 'es' : 'en'
}

/** The active language tag, for code outside React components (e.g. the API client). */
export function currentLanguage(): Lang {
  return currentLang
}

const es: Record<string, string> = {
  ...coordinatorSpanish,

  // Language switcher
  Language: 'Idioma',

  // Layout
  Missions: 'Misiones',
  Teams: 'Equipos',
  Templates: 'Plantillas',
  Providers: 'Proveedores',
  People: 'Personas',
  Account: 'Cuenta',
  'Sign out': 'Cerrar sesión',
  More: 'Más',
  'AgentSam home': 'Inicio de AgentSam',
  Main: 'Principal',
  admin: 'admin',
  member: 'miembro',

  // Shared
  Loading: 'Cargando',
  Name: 'Nombre',
  Email: 'Correo electrónico',
  Role: 'Rol',
  Member: 'Miembro',
  Admin: 'Administrador',
  Copy: 'Copiar',
  Copied: 'Copiado',
  Revoke: 'Revocar',
  Remove: 'Eliminar',
  Delete: 'Eliminar',
  Cancel: 'Cancelar',
  'Saving…': 'Guardando…',
  'Launching…': 'Lanzando…',
  'Testing…': 'Probando…',
  'Test connection': 'Probar conexión',
  'key saved': 'clave guardada',
  'no key': 'sin clave',
  'At least 12 characters.': 'Al menos 12 caracteres.',
  'Your name': 'Tu nombre',
  Password: 'Contraseña',
  'Confirm password': 'Confirmar contraseña',
  'Passwords don’t match': 'Las contraseñas no coinciden',
  'by {name}': 'por {name}',
  'Something went wrong': 'Algo salió mal',

  // Mission status / phase / agent state labels
  queued: 'en cola',
  running: 'en marcha',
  completed: 'completada',
  failed: 'fallida',
  stopped: 'detenida',
  all: 'todas',
  idle: 'en espera',
  working: 'trabajando',
  done: 'terminado',
  attention: 'atención',
  '● Queued': '● En cola',
  '● Running': '● En marcha',
  '✓ Done': '✓ Terminada',
  '✕ Failed': '✕ Fallida',
  '■ Stopped': '■ Detenida',
  Planning: 'Planificando',
  'Agents working': 'Agentes trabajando',
  Verifying: 'Verificando',
  'Final report': 'Informe final',
  Done: 'Terminada',
  coordinator: 'coordinador',
  worker: 'trabajador',
  verifier: 'verificador',
  'Agent stage': 'Escenario de agentes',

  // Missions page
  'What your teams are working on': 'En qué están trabajando tus equipos',
  'New mission': 'Nueva misión',
  'No provider has an API key yet, so missions can’t run.': 'Ningún proveedor tiene una clave de API todavía, así que las misiones no pueden ejecutarse.',
  'Finish setup': 'Terminar configuración',
  'Search objectives and teams': 'Buscar objetivos y equipos',
  'Search missions': 'Buscar misiones',
  'Filter by status': 'Filtrar por estado',
  'No missions yet. Give a team its first objective.': 'Aún no hay misiones. Dale a un equipo su primer objetivo.',
  'Launch a mission': 'Lanzar una misión',
  'No missions match.': 'Ninguna misión coincide.',
  '● {count} running · Missions': '● {count} en marcha · Misiones',

  // Teams page
  'Your agent teams': 'Tus equipos de agentes',
  'Browse templates': 'Explorar plantillas',
  'New team': 'Nuevo equipo',
  'No teams yet.': 'Aún no hay equipos.',
  'Hire one from a template': 'Contrata uno desde una plantilla',
  '{count} agents': '{count} agentes',

  // Templates page
  'Hire a team in one click.': 'Contrata un equipo con un clic.',
  'Each squad comes with a coordinator, specialists and a verifier. You can tune every agent afterwards.':
    'Cada equipo viene con un coordinador, especialistas y un verificador. Puedes ajustar cada agente después.',
  'low cost': 'bajo coste',
  'no model': 'sin modelo',
  'Try: “{example}”': 'Prueba: “{example}”',
  'Hide squad': 'Ocultar equipo',
  'Meet the squad': 'Conoce al equipo',
  'Hiring…': 'Contratando…',
  'Hire team': 'Contratar equipo',

  // Mission detail page
  'Stop this mission? Agents stop where they are, and it can’t be resumed.':
    '¿Detener esta misión? Los agentes paran donde están y no se puede reanudar.',
  'Delete this mission and all its files? This can’t be undone.': '¿Eliminar esta misión y todos sus archivos? Esto no se puede deshacer.',
  Stop: 'Detener',
  'Follow up': 'Seguimiento',
  'Run again': 'Ejecutar de nuevo',
  plan: 'plan',
  chatter: 'conversación',
  files: 'archivos',
  activity: 'actividad',
  'The coordinator is planning…': 'El coordinador está planificando…',
  'No plan was recorded.': 'No se registró ningún plan.',
  '{input} in · {output} out': '{input} ent. · {output} sal.',
  '● Live': '● En vivo',
  'Reconnecting…': 'Reconectando…',
  'Connecting…': 'Conectando…',
  'Nothing said yet.': 'Aún no se ha dicho nada.',
  mission: 'misión',
  'Show {count} earlier events ({hidden} hidden)': 'Mostrar {count} eventos anteriores ({hidden} ocultos)',
  'No files yet. Agents write their deliverables here.': 'Aún no hay archivos. Los agentes escriben sus entregables aquí.',
  'Zipping…': 'Comprimiendo…',
  'Download all': 'Descargar todo',
  Download: 'Descargar',

  // New mission page
  'What should the team do?': '¿Qué debe hacer el equipo?',
  'The coordinator turns your objective into tasks, workers run them in parallel, and the verifier checks the results.':
    'El coordinador convierte tu objetivo en tareas, los trabajadores las ejecutan en paralelo y el verificador comprueba los resultados.',
  'You need a team first.': 'Primero necesitas un equipo.',
  'Hire a team': 'Contratar un equipo',
  Team: 'Equipo',
  Objective: 'Objetivo',
  'e.g. Research the top five open-source vector databases and write a comparison with a recommendation.':
    'p. ej. Investiga las cinco principales bases de datos vectoriales de código abierto y escribe una comparación con una recomendación.',
  Ideas: 'Ideas',
  'Launch mission': 'Lanzar misión',
  'Runs on the server with the provider keys your admin configured.':
    'Se ejecuta en el servidor con las claves de proveedor que configuró tu administrador.',

  // Settings (providers) page
  'Server settings': 'Configuración del servidor',
  'Model providers': 'Proveedores de modelos',
  'Keys are stored on the server and shared by every mission. They can be replaced or removed here, but never read back.':
    'Las claves se guardan en el servidor y las comparten todas las misiones. Se pueden reemplazar o eliminar aquí, pero nunca se pueden leer.',
  'Add provider': 'Añadir proveedor',
  'Provider saved.': 'Proveedor guardado.',
  'Key saved': 'Clave guardada',
  'Key saved, but the test failed: {message}': 'Clave guardada, pero la prueba falló: {message}',
  'New provider': 'Nuevo proveedor',
  Id: 'Id',
  'API style': 'Estilo de API',
  'Base URL': 'URL base',
  'Default model': 'Modelo predeterminado',
  'Models (comma separated)': 'Modelos (separados por comas)',
  'Paste a new key to replace the saved one': 'Pega una nueva clave para reemplazar la guardada',
  'Paste API key': 'Pega la clave de API',
  'API key for {name}': 'Clave de API para {name}',
  'Save and test key': 'Guardar y probar clave',
  'Save provider': 'Guardar proveedor',
  'Edit models and URL': 'Editar modelos y URL',
  'Remove the saved {name} key? Agents using it will stop working.':
    '¿Eliminar la clave guardada de {name}? Los agentes que la usan dejarán de funcionar.',
  'Key removed.': 'Clave eliminada.',
  'Remove key': 'Eliminar clave',
  'Delete the {name} provider and its key?': '¿Eliminar el proveedor {name} y su clave?',
  'Delete provider': 'Eliminar proveedor',

  // Account page
  'Signed in with the server token': 'Sesión iniciada con el token del servidor',
  'Change password': 'Cambiar contraseña',
  'New passwords don’t match': 'Las contraseñas nuevas no coinciden',
  'Password changed.': 'Contraseña cambiada.',
  'Current password': 'Contraseña actual',
  'New password': 'Nueva contraseña',
  'At least 12 characters. Your other sessions will be signed out.': 'Al menos 12 caracteres. Tus otras sesiones se cerrarán.',
  'Confirm new password': 'Confirmar nueva contraseña',

  // App tokens
  'App tokens': 'Tokens de apps',
  'Use a token in the iPhone or Mac app, in place of the server token, to work as yourself with your own role. Each token is shown once.':
    'Usa un token en la app de iPhone o Mac, en lugar del token del servidor, para trabajar como tú mismo con tu propio rol. Cada token se muestra una vez.',
  'Token name, e.g. My iPhone': 'Nombre del token, p. ej. Mi iPhone',
  'Create token': 'Crear token',
  'Copy this token now. It won’t be shown again.': 'Copia este token ahora. No se mostrará de nuevo.',
  'Revoke this token? Any app using it will be signed out.': '¿Revocar este token? Cualquier app que lo use cerrará sesión.',
  Created: 'Creado',
  'Last used': 'Último uso',

  // People page
  'Who can use this server': 'Quién puede usar este servidor',
  'Everyone shares the same teams and missions. Admins also manage people and provider keys.':
    'Todos comparten los mismos equipos y misiones. Los administradores también gestionan personas y claves de proveedor.',
  'Invite someone': 'Invitar a alguien',
  'Email to invite': 'Correo a invitar',
  'Create invite link': 'Crear enlace de invitación',
  'Send this link to them. It works once and expires in 7 days. It won’t be shown again.':
    'Envíales este enlace. Funciona una vez y caduca en 7 días. No se mostrará de nuevo.',
  Members: 'Miembros',
  'Last sign-in': 'Último acceso',
  you: 'tú',
  disabled: 'desactivado',
  'Role for {name}': 'Rol de {name}',
  Enable: 'Activar',
  Disable: 'Desactivar',
  'Remove {name}? They’ll be signed out immediately.': '¿Eliminar a {name}? Su sesión se cerrará inmediatamente.',
  'Pending invites': 'Invitaciones pendientes',
  Expires: 'Caduca',

  // Login page
  'Welcome back': 'Bienvenido de nuevo',
  'Sign in': 'Iniciar sesión',
  'Your agent team is waiting.': 'Tu equipo de agentes te espera.',
  'Signing in…': 'Iniciando sesión…',
  'No account? Ask an admin for an invite link.': '¿Sin cuenta? Pide a un administrador un enlace de invitación.',

  // Setup page
  'First run': 'Primera ejecución',
  'Create the admin account': 'Crear la cuenta de administrador',
  'Prove you own this server with its': 'Demuestra que eres dueño de este servidor con su',
  '(in Railway’s variables), then pick your sign-in.': '(en las variables de Railway) y luego elige tus credenciales.',
  'Server token': 'Token del servidor',
  'Creating…': 'Creando…',
  'Create admin and sign in': 'Crear administrador e iniciar sesión',

  // Invite page
  'This invite link is incomplete. Ask your admin to send it again.':
    'Este enlace de invitación está incompleto. Pide a tu administrador que lo envíe de nuevo.',
  'Invite unavailable': 'Invitación no disponible',
  'Go to sign in': 'Ir a iniciar sesión',
  'You’re invited': 'Estás invitado',
  'Join AgentSam': 'Únete a AgentSam',
  'Creating an account for {email} as {role}.': 'Creando una cuenta para {email} como {role}.',
  'an admin': 'un administrador',
  'a member': 'un miembro',
  'Creating account…': 'Creando cuenta…',
  'Create account': 'Crear cuenta',

  // Welcome (guided setup) page
  'Get started': 'Primeros pasos',
  'Connect models': 'Conecta modelos',
  'First mission': 'Primera misión',
  'Skip setup': 'Omitir configuración',
  'Step {number}': 'Paso {number}',
  'Connect your models.': 'Conecta tus modelos.',
  'Bring your own key. It’s stored on the server and every mission uses it, for everyone.':
    'Trae tu propia clave. Se guarda en el servidor y todas las misiones la usan, para todos.',
  'Key saved. Paste a new one to replace it.': 'Clave guardada. Pega una nueva para reemplazarla.',
  'Paste your {name} API key': 'Pega tu clave de API de {name}',
  Next: 'Siguiente',
  'Who do you need?': '¿A quién necesitas?',
  'Pick a squad. You can rename agents and change their models later in Teams.':
    'Elige un equipo. Puedes renombrar agentes y cambiar sus modelos luego en Equipos.',
  'Your first mission.': 'Tu primera misión.',
  '{team} is ready, {name}. What should they work on?': '{team} está listo, {name}. ¿En qué deberían trabajar?',
  'Hire a team first.': 'Primero contrata un equipo.',
  'Describe the objective': 'Describe el objetivo',

  // Team edit page
  'A team needs exactly one coordinator.': 'Un equipo necesita exactamente un coordinador.',
  'Add at least one worker.': 'Añade al menos un trabajador.',
  'Use at most one verifier.': 'Usa como máximo un verificador.',
  'Agent names must be unique (the plan assigns tasks by name).': 'Los nombres de los agentes deben ser únicos (el plan asigna tareas por nombre).',
  'Every agent needs a name.': 'Cada agente necesita un nombre.',
  'Every agent needs a provider and model.': 'Cada agente necesita un proveedor y un modelo.',
  'Delete {name}? Past missions stay, but the team can’t run new ones.':
    '¿Eliminar {name}? Las misiones pasadas se conservan, pero el equipo no podrá ejecutar nuevas.',
  Saved: 'Guardado',
  'Save team': 'Guardar equipo',
  Emoji: 'Emoji',
  'Team name': 'Nombre del equipo',
  Goal: 'Objetivo',
  'What this team is for': 'Para qué sirve este equipo',
  'Unnamed agent': 'Agente sin nombre',
  Title: 'Título',
  Coordinator: 'Coordinador',
  Worker: 'Trabajador',
  Verifier: 'Verificador',
  Provider: 'Proveedor',
  Model: 'Modelo',
  Temperature: 'Temperatura',
  'Choose…': 'Elegir…',
  '(no key)': '(sin clave)',
  default: 'predeterminado',
  'System prompt': 'Prompt del sistema',
  'Add worker': 'Añadir trabajador',
  'Add verifier': 'Añadir verificador',
  'Delete team': 'Eliminar equipo',
}

type Vars = Record<string, string | number>

function translateIn(lang: Lang, key: string, vars?: Vars): string {
  let text = lang === 'es' ? (es[key] ?? key) : key
  if (vars) for (const [name, value] of Object.entries(vars)) text = text.replaceAll(`{${name}}`, String(value))
  return text
}

/** Translates an English source string into the active language, for code outside React components. */
export function translate(key: string, vars?: Vars): string {
  return translateIn(currentLang, key, vars)
}

interface I18nValue {
  lang: Lang
  setLang: (lang: Lang) => void
  t: typeof translate
}

const I18nContext = createContext<I18nValue>({ lang: 'en', setLang: () => {}, t: translate })

export function I18nProvider({ children }: { children: ReactNode }) {
  // Resolve during the first render (not in an effect) so translated text is correct on first paint.
  const [lang, setLangState] = useState<Lang>(() => {
    currentLang = initialLang()
    return currentLang
  })

  useEffect(() => {
    currentLang = lang
    document.documentElement.lang = lang
    try {
      localStorage.setItem(STORAGE_KEY, lang)
    } catch {
      // Keep the in-memory language when storage is unavailable.
    }
  }, [lang])

  // t reads the state (not the module variable, which effects update a render late),
  // so switching languages re-renders every string immediately.
  const value: I18nValue = { lang, setLang: setLangState, t: (key, vars) => translateIn(lang, key, vars) }
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}

export function useI18n(): I18nValue {
  return useContext(I18nContext)
}
