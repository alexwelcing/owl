(*
 * OWL - an OCaml numerical library for scientific computing
 * Copyright (c) 2016-2017 Liang Wang <liang.wang@cl.cam.ac.uk>
 *)

open Owl_nlp_utils

type t = {
  mutable text_uri   : string option;       (* path of the text corpus *)
  mutable text_h     : in_channel option;   (* file handle of the corpus *)
  mutable token_uri  : string option;       (* path of the tokenised corpus *)
  mutable token_h    : in_channel option;   (* file handle of the tokens *)
  mutable vocabulary : Owl_nlp_vocabulary.t option; (* vocabulary *)
  mutable num_doc    : int;                 (* number of documents in the corpus *)
}

let _close_if_open = function
  | Some h -> close_in h
  | None   -> ()

let _open_if_exists f =
  match Sys.file_exists f with
  | true  -> Some (open_in f)
  | false -> None

let cleanup x =
  _close_if_open x.text_h;
  _close_if_open x.token_h

let empty () =
  let x = {
    text_uri   = None;
    text_h     = None;
    token_uri  = None;
    token_h    = None;
    vocabulary = None;
    num_doc    = 0;
  }
  in
  Gc.finalise cleanup x;
  x

let create fname =
  let x = {
    text_uri   = Some fname;
    text_h     = _open_if_exists fname;
    token_uri  = Some (fname ^ ".token");
    token_h    = _open_if_exists (fname ^ ".token");
    vocabulary = None;
    num_doc    = 0;
  }
  in
  Gc.finalise cleanup x;
  x

let get_text_uri corpus =
  match corpus.text_uri with
  | Some x -> x
  | None   -> failwith "get_uri: no text_uri has been defined"

let get_text_h corpus =
  match corpus.text_h with
  | Some x -> x
  | None   ->
    let h = corpus |> get_text_uri |> open_in
    in corpus.text_h <- Some h; h

let get_token_uri corpus =
  match corpus.token_uri with
  | Some x -> x
  | None   -> failwith "get_uri: no token_uri has been defined"

let get_token_h corpus =
  match corpus.token_h with
  | Some x -> x
  | None   ->
    let h = corpus |> get_token_uri |> open_in
    in corpus.token_h <- Some h; h

let get_vocabulary corpus =
  match corpus.vocabulary with
  | Some x -> x
  | None   -> failwith "get_vocabulary: it has not been built"

let get_num_doc corpus = corpus.num_doc

let set_num_doc corpus n = corpus.num_doc <- n

let count_num_doc corpus =
  let n = ref 0 in
  let uri = get_text_uri corpus in
  Owl_nlp_utils.iteri_lines_of_file (fun i _ -> n := i) uri;
  !n + 1


(* iterate docs and tokenised docs and etc. *)

let next_doc corpus : string = corpus |> get_text_h |> input_line

let next_tokenised_doc corpus : int array = corpus |> get_token_h |> Marshal.from_channel

let iteri_docs f corpus = iteri_lines_of_file f (get_text_uri corpus)

let iteri_tokenised_docs f corpus = iteri_lines_of_marshal f (get_token_uri corpus)

let mapi_docs f corpus = mapi_lines_of_file f (get_text_uri corpus)

let mapi_tokenised_docs f corpus = mapi_lines_of_marshal f (get_token_uri corpus)


(* reset all the file pointers at offest 0 *)
let reset_iterators corpus =
  let _reset_offset = function
    | Some h -> seek_in h 0
    | None   -> ()
  in
  _reset_offset corpus.text_h;
  _reset_offset corpus.token_h


(* tokenise a corpus and keep the tokens in memory *)
let tokenise_mem dict fname =
  mapi_lines_of_file (fun _ s ->
    Str.split (Str.regexp " ") s
    |> List.filter (Owl_nlp_vocabulary.exits_w dict)
    |> List.map (Owl_nlp_vocabulary.word2index dict)
    |> Array.of_list
  ) fname


(* tokenise a corpus and save the outcome tokens in anther file *)
let tokenise_file dict fi_name fo_name =
  let fo = open_out fo_name in
  iteri_lines_of_file (fun _ s ->
    let t = Str.split (Str.regexp " ") s
      |> List.filter (Owl_nlp_vocabulary.exits_w dict)
      |> List.map (Owl_nlp_vocabulary.word2index dict)
      |> Array.of_list
    in
    Marshal.to_channel fo t [];
  ) fi_name;
  close_out fo


let tokenise_str corpus s =
  let dict = get_vocabulary corpus in
  Str.split (Str.regexp " ") s
  |> List.filter (Owl_nlp_vocabulary.exits_w dict)
  |> List.map (Owl_nlp_vocabulary.word2index dict)
  |> Array.of_list


let tokenise corpus =
  let fi_name = get_text_uri corpus in
  let fo_name = get_token_uri corpus in
  let dict = get_vocabulary corpus in
  tokenise_file dict fi_name fo_name


let build_vocabulary ?lo ?hi ?stopwords corpus =
  let fname = corpus |> get_text_uri in
  let d = Owl_nlp_vocabulary.build_from_file ?lo ?hi ?stopwords fname in
  corpus.vocabulary <- Some d;
  d


(* convert corpus into binary format, build dictionary, tokenise *)
let build ?lo ?hi ?stopwords fname =
  Log.info "build up vocabulary ...";
  let vocab = Owl_nlp_vocabulary.build_from_file ?lo ?hi ?stopwords fname in

  (* prepare the output file *)
  let bin_f = fname ^ ".bin" |> open_out in
  let tok_f = fname ^ ".tok" |> open_out in
  set_binary_mode_out bin_f true;
  set_binary_mode_out tok_f true;

  (* initalise the offset array *)
  let b_ofs = Owl_utils.Stack.make () in
  let t_ofs = Owl_utils.Stack.make () in
  Owl_utils.Stack.push b_ofs 0;
  Owl_utils.Stack.push t_ofs 0;

  (* binarise and tokenise at the same time *)
  Log.info "convert to binary and tokenise ...";
  iteri_lines_of_file (fun i s ->

    let t = Str.split (Str.regexp " ") s
      |> List.filter (Owl_nlp_vocabulary.exits_w vocab)
      |> List.map (Owl_nlp_vocabulary.word2index vocab)
      |> Array.of_list
    in
    Marshal.to_channel bin_f s [];
    Marshal.to_channel tok_f t [];

    Owl_utils.Stack.push b_ofs (LargeFile.pos_out bin_f |> Int64.to_int);
    Owl_utils.Stack.push t_ofs (LargeFile.pos_out tok_f |> Int64.to_int);

  ) fname;

  (* save index file *)
  let idx_f = fname ^ ".idx" |> open_out in
  let b_ofs = Owl_utils.Stack.to_array b_ofs in
  let t_ofs = Owl_utils.Stack.to_array t_ofs in
  Marshal.to_channel idx_f (b_ofs, t_ofs) [];

  (* done, close the files *)
  close_out bin_f;
  close_out tok_f;
  close_out idx_f



(* i/o: save and load corpus *)

(* set file handle to None so it can safely saved *)
let copy_model corpus = {
  text_uri   = corpus.text_uri;
  text_h     = None;
  token_uri  = corpus.token_uri;
  token_h    = None;
  vocabulary = corpus.vocabulary;
  num_doc    = corpus.num_doc;
}

let save corpus f =
  let x = copy_model corpus in
  Owl_utils.marshal_to_file x f

let load f : t = Owl_utils.marshal_from_file f


(* TODO: for debug atm, need to optimise *)

let get_doc corpus i =
  let doc = ref "" in
  (
    try iteri_lines_of_file (fun j s ->
      if i = j then (
        doc := s;
        failwith "found";
      )
    ) (get_text_uri corpus)
    with exn -> ()
  );
  !doc

(* ends here *)
