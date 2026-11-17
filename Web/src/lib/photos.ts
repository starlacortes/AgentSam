/** Photos attached in the composer: shrunk in the browser before upload. */

/** The long edge vision models work best at; bigger photos only cost more and upload slower. */
export const MAX_PHOTO_EDGE = 1568
export const MAX_PHOTOS = 4
const JPEG_QUALITY = 0.85

export interface PendingPhoto {
  key: string
  name: string
  blob: Blob
  /** An object URL for the thumbnail; revoke it when the photo is removed or sent. */
  url: string
}

let counter = 0

export function isPhotoFile(file: File): boolean {
  return file.type.startsWith('image/') || /\.(jpe?g|png|webp|gif|heic|heif)$/i.test(file.name)
}

/** Scales `width` × `height` down so the long edge is at most `max`, keeping the aspect ratio. */
export function fitWithin(width: number, height: number, max = MAX_PHOTO_EDGE): { width: number; height: number } {
  const long = Math.max(width, height)
  if (!long || long <= max) return { width, height }
  const scale = max / long
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) }
}

async function decode(file: Blob): Promise<{ source: CanvasImageSource; width: number; height: number; close: () => void }> {
  if (typeof createImageBitmap === 'function') {
    try {
      const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
      return { source: bitmap, width: bitmap.width, height: bitmap.height, close: () => bitmap.close() }
    } catch { /* Fall back to an <img>, which decodes some formats (like HEIC on Safari) that bitmaps don't. */ }
  }
  const url = URL.createObjectURL(file)
  try {
    const image = new Image()
    image.decoding = 'async'
    image.src = url
    await image.decode()
    return { source: image, width: image.naturalWidth, height: image.naturalHeight, close: () => URL.revokeObjectURL(url) }
  } catch (error) {
    URL.revokeObjectURL(url)
    throw error
  }
}

/**
 * Turns a camera or library photo into a JPEG of at most 1568px on the long edge. Re-encoding also
 * drops the photo's metadata, such as its GPS location, before it leaves the device.
 */
export async function preparePhoto(file: File): Promise<PendingPhoto> {
  const decoded = await decode(file)
  try {
    const size = fitWithin(decoded.width, decoded.height)
    const canvas = document.createElement('canvas')
    canvas.width = size.width
    canvas.height = size.height
    const context = canvas.getContext('2d')
    if (!context) throw new Error('canvas')
    // JPEG has no transparency: put see-through PNGs on white rather than black.
    context.fillStyle = '#ffffff'
    context.fillRect(0, 0, size.width, size.height)
    context.drawImage(decoded.source, 0, 0, size.width, size.height)
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/jpeg', JPEG_QUALITY))
    if (!blob) throw new Error('encode')
    counter += 1
    return { key: `photo-${Date.now()}-${counter}`, name: file.name || 'photo.jpg', blob, url: URL.createObjectURL(blob) }
  } finally {
    decoded.close()
  }
}

export function photoURL(conversationID: string, photoID: string): string {
  return `/api/conversations/${encodeURIComponent(conversationID)}/photos/${encodeURIComponent(photoID)}`
}
