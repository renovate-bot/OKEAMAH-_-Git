(* Verify the default behavior of split is handling multiple instances of the
   separator in a row
 *)
let test_split_duplicated_separator () =
  let inputs =
    [
      "Hello World";
      "Hello  World";
      "HelloWorld";
      "Hello                       World  ";
      "  Hello                       World  ";
      "  Hello                       World";
    ]
  in
  List.iter
    (fun s -> assert (TzString.split ' ' s = TzString.split ' ' s))
    inputs

let test_split_exact =
  let open QCheck2 in
  let gen =
    let open Gen in
    let* str = string_size ~gen:printable (6 -- 128) in
    let* lim = opt (1 -- 32) in
    let* sep = printable in
    return (str, sep, lim)
  in
  Test.make
    ~name:"TzString.split_exact is reversed by String.concat"
    gen
    (fun (string, sep, limit) ->
      let split = TzString.split_exact sep ?limit string in
      String.concat (String.init 1 (fun _ -> sep)) split = string)

let split_tests =
  [("handles a duplicated separator", `Quick, test_split_duplicated_separator)]
  @ Lib_test.Qcheck2_helpers.qcheck_wrap [test_split_exact]

let () = Alcotest.run "TzString" [("split", split_tests)]
