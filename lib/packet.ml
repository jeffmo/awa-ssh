(*
 * Copyright (c) 2017 Christiano F. Haesbaert <haesbaert@haesbaert.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Sexplib.Conv
open Rresult.R
open Util

let hmac mac buf =
  let hmac = mac.Hmac.hmac in
  let key = mac.Hmac.key in
  let seq = mac.Hmac.seq in
  let seqbuf = Cstruct.create 4 in
  Cstruct.BE.set_uint32 seqbuf 0 seq;
  let digest = Hmac.hmacv hmac ~key [ seqbuf; buf ] in
  digest, Hmac.{ mac with seq = Int32.succ seq }

(* For some reason Nocrypto CTR modifies ctr in place, CBC returns next *)
let cipher_enc_dec enc cipher buf =
  let open Nocrypto.Cipher_block in
  let iv = cipher.Cipher.cipher_iv in
  match cipher.Cipher.cipher_key with
  | Cipher.Plaintext_key -> buf, cipher
  | Cipher.Aes_ctr_key key ->
    let f = if enc then AES.CTR.encrypt else AES.CTR.decrypt in
    let buf = f ~key ~ctr:iv buf in
    let blocks = (Cstruct.len buf) / AES.CTR.block_size |> Int64.of_int in
    let iv_len = Cstruct.len iv in
    let next_iv = Cstruct.create iv_len in
    Cstruct.blit iv 0 next_iv 0 iv_len;
    (* Update ctr with number of blocks *)
    Counter.add16 next_iv 0 blocks;
    let key = Cipher.{ cipher with cipher_iv = next_iv } in
    buf, key
  | Cipher.Aes_cbc_key key ->
    let f = if enc then AES.CBC.encrypt else AES.CBC.decrypt in
    let buf = f ~key ~iv buf in
    let next_iv = AES.CBC.next_iv ~iv buf in
    let cipher = Cipher.{ cipher with cipher_iv = next_iv } in
    buf, cipher

let cipher_encrypt = cipher_enc_dec true
let cipher_decrypt = cipher_enc_dec false

let peek_len cipher block_len buf =
  let open Nocrypto.Cipher_block in
  assert (block_len <= (Cstruct.len buf));
  let buf = Cstruct.set_len buf block_len in
  let hdr = match cipher.Cipher.cipher_key with
    | Cipher.Plaintext_key -> buf
    | Cipher.Aes_ctr_key key -> AES.CTR.decrypt ~key ~ctr:cipher.Cipher.cipher_iv buf
    | Cipher.Aes_cbc_key key -> AES.CBC.decrypt ~key ~iv:cipher.Cipher.cipher_iv buf
  in
  Ssh.get_pkt_hdr_pkt_len hdr |> Int32.to_int

let partial buf =
  if (Cstruct.len buf) < Ssh.max_pkt_len then
    ok None
  else
    error "Buffer is too big"

let to_msg pkt =
  Wire.get_payload pkt >>= Wire.get_message

let decrypt keys buf =
  let open Ssh in
  let cipher = keys.Kex.cipher in
  let mac = keys.Kex.mac in
  let block_len = max 8 (Cipher.block_len cipher.Cipher.cipher) in
  let digest_len = Hmac.(digest_len mac.hmac) in
  if (Cstruct.len buf) < (sizeof_pkt_hdr + digest_len + block_len) then
    partial buf
  else
    let pkt_len = peek_len cipher block_len buf in
    guard (pkt_len > 0 && pkt_len < max_pkt_len) "decrypt: Bogus pkt len"
    >>= fun () ->
    if (Cstruct.len buf) < (pkt_len + 4 + digest_len) then
      partial buf
    else
      let pkt_enc = Cstruct.set_len buf (pkt_len + 4) in
      let tx_rx = Int64.add keys.Kex.tx_rx
          (Cstruct.len pkt_enc |> Int64.of_int)
      in
      let derived = keys.Kex.derived in
      let pkt_dec, cipher = cipher_decrypt cipher pkt_enc in
      let digest1 = Cstruct.shift buf (pkt_len + 4) in
      let digest1 = Cstruct.set_len digest1 digest_len in
      let digest2, mac = hmac mac pkt_dec in
      guard (Cstruct.equal digest1 digest2)
        "decrypt: Bad digest" >>= fun () ->
      let pad_len = get_pkt_hdr_pad_len pkt_dec in
      guard (pad_len >= 4 && pad_len <= 255 && pad_len < pkt_len)
        "decrypt: Bogus pad len"  >>= fun () ->
      let buf = Cstruct.shift buf (4 + pkt_len + digest_len) in
      let keys = Kex.{ cipher; mac; tx_rx; derived } in
      ok (Some (pkt_dec, buf, keys))

let encrypt keys msg =
  let cipher = keys.Kex.cipher in
  let mac = keys.Kex.mac in
  let block_len = max 8 (Cipher.block_len cipher.Cipher.cipher) in
  (* packet_length + padding_length + payload - sequence_length *)
  let buf = Dbuf.reserve Ssh.sizeof_pkt_hdr (Dbuf.create ()) |> Wire.put_message msg in
  let len = Dbuf.used buf in
  (* calculate padding *)
  let padlen =
    let x = block_len - (len mod block_len) in
    if x < 4 then x + block_len else x
  in
  assert (padlen >= 4 && padlen <= 255);
  let pkt = Wire.put_random padlen buf |> Dbuf.to_cstruct in
  Ssh.set_pkt_hdr_pkt_len pkt (Int32.of_int ((Cstruct.len pkt) - 4));
  Ssh.set_pkt_hdr_pad_len pkt padlen;
  let digest, mac = hmac mac pkt in
  let enc, cipher = cipher_encrypt cipher pkt in
  let packet = Cstruct.append enc digest in
  let tx_rx = Int64.add keys.Kex.tx_rx
      (Cstruct.len packet |> Int64.of_int)
  in
  let derived = keys.Kex.derived in
  let keys = Kex.{ cipher; mac; tx_rx; derived } in
  packet, keys
