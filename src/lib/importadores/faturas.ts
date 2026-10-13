// Leitores de FATURA em PDF disponíveis, todos feitos e conferidos com
// arquivos reais. A ordem importa pouco: cada um só reconhece o layout do
// próprio banco.
import type { FaturaLida } from "./fatura-comum.ts";
import type { LinhaPdf } from "./pdf.ts";
import { lerNubankFaturaPdf, reconheceNubankFatura } from "./nubank-fatura-pdf.ts";
import { lerItauFaturaPdf, reconheceItauFatura } from "./itau-fatura-pdf.ts";
import { lerSantanderFaturaPdf, reconheceSantanderFatura } from "./santander-fatura-pdf.ts";
import { lerMercadoPagoFaturaPdf, reconheceMercadoPagoFatura } from "./mercadopago-fatura-pdf.ts";
import { lerSicrediFaturaPdf, reconheceSicrediFatura } from "./sicredi-fatura-pdf.ts";
import { lerSicoobFaturaPdf, reconheceSicoobFatura } from "./sicoob-fatura-pdf.ts";
import { lerRiachueloFaturaPdf, reconheceRiachueloFatura } from "./riachuelo-fatura-pdf.ts";

export type LeitorFatura = { id: string; banco: string; reconhece: (l: LinhaPdf[]) => boolean; ler: (l: LinhaPdf[]) => FaturaLida };

export const LEITORES_FATURA: LeitorFatura[] = [
  { id: "nubank-fatura-pdf", banco: "Nubank", reconhece: reconheceNubankFatura, ler: lerNubankFaturaPdf },
  { id: "itau-fatura-pdf", banco: "Itaú", reconhece: reconheceItauFatura, ler: lerItauFaturaPdf },
  { id: "santander-fatura-pdf", banco: "Santander", reconhece: reconheceSantanderFatura, ler: lerSantanderFaturaPdf },
  { id: "mercadopago-fatura-pdf", banco: "Mercado Pago", reconhece: reconheceMercadoPagoFatura, ler: lerMercadoPagoFaturaPdf },
  { id: "sicredi-fatura-pdf", banco: "Sicredi", reconhece: reconheceSicrediFatura, ler: lerSicrediFaturaPdf },
  { id: "sicoob-fatura-pdf", banco: "Sicoob", reconhece: reconheceSicoobFatura, ler: lerSicoobFaturaPdf },
  { id: "riachuelo-fatura-pdf", banco: "Riachuelo", reconhece: reconheceRiachueloFatura, ler: lerRiachueloFaturaPdf },
];
