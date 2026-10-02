// One env read that works wherever the sync runs: Node on the owner's PC (the
// original home) and Deno inside the Supabase edge function (item 48) alike.
export const env = (k) => globalThis.Deno?.env?.get?.(k) ?? globalThis.process?.env?.[k]
