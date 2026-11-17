import { describe, expect, it } from 'vitest'
import { fitWithin, isPhotoFile, MAX_PHOTO_EDGE, photoURL } from './photos'

describe('photos', () => {
  it('shrinks the long edge to the model size and keeps the aspect ratio', () => {
    expect(fitWithin(4032, 3024)).toEqual({ width: MAX_PHOTO_EDGE, height: 1176 })
    expect(fitWithin(3024, 4032)).toEqual({ width: 1176, height: MAX_PHOTO_EDGE })
    expect(fitWithin(800, 600)).toEqual({ width: 800, height: 600 })
    expect(fitWithin(10000, 10)).toEqual({ width: MAX_PHOTO_EDGE, height: 2 })
  })

  it('recognises photos from the camera, the library, and pasted screenshots', () => {
    expect(isPhotoFile(new File(['x'], 'image.png', { type: 'image/png' }))).toBe(true)
    expect(isPhotoFile(new File(['x'], 'IMG_0001.HEIC', { type: '' }))).toBe(true)
    expect(isPhotoFile(new File(['x'], 'notes.md', { type: 'text/markdown' }))).toBe(false)
  })

  it('builds the photo address the server serves', () => {
    expect(photoURL('chat 1', 'abc')).toBe('/api/conversations/chat%201/photos/abc')
  })
})
