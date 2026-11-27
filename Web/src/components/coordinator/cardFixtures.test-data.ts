import type { InfoCard } from '../../api/types'

const base = { items: [], columns: [], rows: [] }

/** One card of each template, as Ada would send them. Used by the tests and the screenshot page. */
export function sampleCards(lang: 'en' | 'es' = 'en'): InfoCard[] {
  const es = lang === 'es'
  return [
    { ...base, id: 's', template: 'stats', title: es ? 'Noviembre, hasta hoy' : 'November so far', note: es ? 'Fuente: Google Ads, 1–27 nov' : 'Source: Google Ads, Nov 1–27', items: [
      { label: es ? 'Gasto' : 'Spend', value: '$1,284', detail: es ? '+8% vs oct' : '+8% vs Oct', tone: 'neutral' },
      { label: es ? 'Clientes potenciales' : 'Leads', value: '46', detail: es ? '+21% vs oct' : '+21% vs Oct', tone: 'good' },
      { label: es ? 'Coste por cliente' : 'Cost per lead', value: '$27.90', detail: es ? '−11% vs oct' : '−11% vs Oct', tone: 'good' },
      { label: es ? 'Tasa de clics' : 'Click rate', value: '3.1%', detail: es ? '−0.4 pts' : '−0.4 pts', tone: 'bad' },
    ] },
    { ...base, id: 'c', template: 'comparison', title: es ? 'Planes de alojamiento' : 'Hosting plans', highlight: 1, columns: ['Starter', 'Business', 'Agency'], rows: [
      { label: es ? 'Precio' : 'Price', values: [es ? '$9/mes' : '$9/mo', es ? '$19/mes' : '$19/mo', es ? '$49/mes' : '$49/mo'] },
      { label: es ? 'Sitios' : 'Sites', values: ['1', '5', '25'] },
      { label: es ? 'Copias' : 'Backups', values: [es ? 'Semanal' : 'Weekly', es ? 'Diaria' : 'Daily', es ? 'Cada hora' : 'Hourly'] },
      { label: es ? 'Soporte' : 'Support', values: ['Email', 'Chat', es ? 'Teléfono' : 'Phone'] },
    ] },
    { ...base, id: 'r', template: 'ranking', title: es ? 'Páginas más visitadas' : 'Top pages this week', unit: es ? 'visitas' : 'visits', items: [
      { label: '/pricing', value: '1,240', number: 1240 },
      { label: '/', value: '980', number: 980 },
      { label: es ? '/servicios/limpieza' : '/services/deep-clean', value: '612', number: 612, detail: es ? 'Subió 3 puestos' : 'Up 3 places' },
      { label: '/contact', value: '301', number: 301 },
    ] },
    { ...base, id: 'b', template: 'chart', chart: 'bar', title: es ? 'Reservas por día' : 'Bookings by day', unit: es ? 'reservas' : 'bookings', items: (es ? ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'] : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']).map((label, i) => ({ label, number: [12, 18, 15, 22, 30, 26, 9][i] })) },
    { ...base, id: 'l', template: 'chart', chart: 'line', title: es ? 'Ingresos mensuales' : 'Monthly revenue', unit: '$', items: (es ? ['jun', 'jul', 'ago', 'sep', 'oct', 'nov'] : ['Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov']).map((label, i) => ({ label, number: [3200, 3550, 3400, 3980, 4210, 4630][i] })) },
    { ...base, id: 'p', template: 'steps', title: es ? 'Mudanza del sitio' : 'Site move', items: [
      { label: es ? 'Copiar archivos' : 'Copy files', state: 'done' },
      { label: es ? 'Apuntar el DNS' : 'Point DNS', state: 'done', detail: es ? 'Cloudflare, registro A' : 'Cloudflare, A record' },
      { label: es ? 'Esperar el certificado' : 'Wait for the certificate', state: 'current', detail: es ? 'Suele tardar 10 minutos' : 'Usually about 10 minutes' },
      { label: es ? 'Probar el formulario' : 'Test the booking form', state: 'todo' },
    ] },
    { ...base, id: 't', template: 'timeline', title: es ? 'Plan de lanzamiento' : 'Launch plan', items: [
      { when: es ? 'lun 2 dic' : 'Mon 2 Dec', label: es ? 'Textos finales' : 'Final copy', detail: es ? 'Revisión de star' : 'Star reviews' },
      { when: es ? 'mié 4 dic' : 'Wed 4 Dec', label: es ? 'Anuncios en marcha' : 'Ads go live' },
      { when: es ? 'lun 9 dic' : 'Mon 9 Dec', label: es ? 'Primer informe' : 'First report', detail: es ? 'Gasto, clientes, coste' : 'Spend, leads, cost per lead' },
    ] },
    { ...base, id: 'k', template: 'summary', title: es ? 'Dominio' : 'Domain', items: [
      { label: es ? 'Nombre' : 'Name', value: 'maloon.example' },
      { label: es ? 'Renueva' : 'Renews', value: es ? '12 ene 2027' : '12 Jan 2027', detail: es ? 'Renovación automática activada' : 'Auto-renew on' },
      { label: 'DNS', value: 'Cloudflare' },
      { label: 'SSL', value: es ? 'Válido, 74 días' : 'Valid, 74 days left' },
    ] },
    { ...base, id: 'w', template: 'callout', tone: 'warning', title: es ? 'La tarjeta caduca pronto' : 'Card expires soon', text: es ? 'La tarjeta que paga Google Ads caduca el 30 de noviembre. Si no se cambia, los anuncios se detendrán.' : 'The card paying for Google Ads expires on 30 November. If it is not replaced, the ads stop.' },
    { ...base, id: 'o', template: 'callout', tone: 'success', text: es ? 'Las tres campañas están activas y dentro del presupuesto.' : 'All three campaigns are live and under budget.' },
  ]
}
