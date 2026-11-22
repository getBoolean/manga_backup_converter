// Pinned host library for Paperback sources (U6). Exposes exactly what the
// Paperback 0.8 toolchain's source tester injects (`require('cheerio').default`)
// and the 0.9 reference polyfill's entity decoder (`entities.decodeHTMLStrict`).
import cheerio from 'cheerio';
import { decodeHTMLStrict } from 'entities';
globalThis.__pbLib = { cheerio, decodeHTMLStrict };
