// Valores injetados no build (build.mjs) a partir das variáveis do Netlify.
declare const __SUPABASE_URL__: string;
declare const __SUPABASE_ANON_KEY__: string;

export const SUPABASE_URL: string = __SUPABASE_URL__;
export const SUPABASE_ANON_KEY: string = __SUPABASE_ANON_KEY__;
declare const __PDFJS_BASE__: string;
/** Pasta do pdf.js servido pelo próprio site (leitura de extratos em PDF). */
export const PDFJS_BASE: string = __PDFJS_BASE__;
