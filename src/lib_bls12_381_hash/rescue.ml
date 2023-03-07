module Stubs = struct
  type ctxt

  external allocate_ctxt :
    Bls12_381.Fr.t array array -> Bls12_381.Fr.t array -> int -> int -> ctxt
    = "caml_bls12_381_hash_rescue_allocate_ctxt_stubs"

  external apply_permutation : ctxt -> unit
    = "caml_bls12_381_hash_rescue_apply_permutation_stubs"

  external get_state : Bls12_381.Fr.t array -> ctxt -> unit
    = "caml_bls12_381_hash_rescue_get_state_stubs"

  external get_state_size : ctxt -> int
    = "caml_bls12_381_hash_rescue_get_state_size_stubs"

  external set_state : ctxt -> Bls12_381.Fr.t array -> unit
    = "caml_bls12_381_hash_rescue_set_state_stubs"
end

module Parameters = struct
  type t = {
    linear_layer : Bls12_381.Fr.t array array;
    round_constants : Bls12_381.Fr.t array;
    state_size : int;
    nb_of_rounds : int;
  }

  let state_size_3_mds =
    [|
      [|
        "343";
        "52435875175126190479447740508185965837690552500527637822603658699938581184114";
        "57";
      |];
      [|
        "19551";
        "52435875175126190479447740508185965837690552500527637822603658699938581162113";
        "2850";
      |];
      [|
        "977550";
        "52435875175126190479447740508185965837690552500527637822603658699938580066914";
        "140050";
      |];
    |]
    |> Array.map (Array.map Bls12_381.Fr.of_string)

  let state_size_3_round_constants =
    [|
      "35495817390819093545263349384941809089491580678942832859579453034368810736263";
      "4734865798690304458175502708216292605326887152358688691882538799996069070938";
      "31271008447681288492961289082649653266089021637020407236527451612237705002107";
      "3752272659749554246987316978069954116630957098620898965749354210894049705204";
      "22641555720019163306763445608116202165619173600682976754848212896631953422071";
      "28122533469631806190969995639553619503758826280316271478360761787725211583550";
      "25847917841495375497002109968427099088777388041775300281757084913772616807196";
      "32694606500120353152300866547101238346520817919199364752958292990138213972843";
      "27286327057691837800467727052167328890802672763096896941933952396730026264130";
      "11421505857991327619183254231367489753132565965114463729904675480639756627135";
      "521411871436069789624101480374109564923458769959324381065745329697883697117";
      "23880784307761253829209017376202022699450440759526482483183942457652656506129";
      "32944735989607121897647886317992117157418889561697480633116336030286723761501";
      "23809168654834556097350366212084670162247725165957937623679460641681583816451";
      "3163860194972429483721954648842733164010713297776971497284575674748141326227";
      "4994154821407041837874226315683255286085207059107827489820229821534877668868";
      "50472710115457611398312524300398743989276776324315737822995925423912734574272";
      "251866835357267652745308982111788504159393069098120092619439598668220537943";
      "29306447221479286209562070090539769526225070913770783266162336064629228514551";
      "29283041777181961494713136804131952798141345310627850728919908467956333015832";
      "28656363295645570828788643827370268834132346888229153863515891780361414296486";
      "25038928963239238795570624926346448459425394096652630785926109997438209703232";
      "8137054880809446884023200631931681550641379823710586899296036975467179806266";
      "40023642373942331790709007028495088784452433159634511649021697266107433596568";
      "35762237949937672281308268151392628513069349315494090383109234785560672634670";
      "30999566811631951689259246295471339743428563889981096112711184113782054324157";
      "20279178450660587763205226449293238908131708902882258115414408411285674682667";
      "7251226788353540177691937542431845975737106489341120571030231114808456476646";
      "52125099959305698802726608420202937507908602874086034970293871469588059526157";
      "36947771116325024965590213964896639663487838999452121836698608133540047510904";
      "6731449362796983987468313257604646517406447849071950000589095424962988643919";
      "46799204329731723451752711923834870677752669570495984560450489328024837708708";
      "35089631385082017128756246668734504606091189119241613702809534617529750689438";
      "48404791586561114467519265925614105026432456534013682923179665391057050944501";
      "25910045457085525717925797997640841840596905619632452927132962053945891631463";
      "1002644049329627578859603332717752156946995816186878866098534634466684910592";
      "27000834541453700882360080348023947440783037764820885196153273422481631245741";
      "12589074081116083610034305532223638886927072126291986576471860562392225733147";
      "42427223203410224646468929039478899902048566366856240877703602702087931641888";
      "13041605696900798404650686538893086909353822453068056131548498883864307018762";
      "7724559080250826493557773439911765324995115520951876421071063545832580076523";
      "2608760983816514764568197126437451665283344192910536302819820213681815485600";
      "4325576551800410431474186754039992813847609089390921236861130833620395142916";
      "28244869281227089786402354774575238327642814071062911402571918173773147690382";
      "52254320812514580546932455788288716956214894268551482805284261007871578815161";
      "44449246366481365934850731985584672122835299278127134772360027315881296465188";
      "38769336262079049280674269301353892930067342680672673045972987208159445324024";
      "42379436704506954159182654240696088598260763773619436089417882065405547940000";
      "22632779538473440042293241998410977359589070603696185849507766111228222504955";
      "15890983544445833013318912933113160561188216234423366865567699135890287302776";
      "42613622386509970285531317746282776785466762852259244468998263414951438072346";
      "3349279328650947992104289938299770603841093392045299702204191673899696292828";
      "24960454956681584943062398789550512391287992748093736571644480050215988836698";
      "31771416517485450527236959099354889665790926800645171236881417310335951093156";
      "6723262288337923380317441046361546981088139618189440979848042063784738198448";
      "34890105450847731125549485970715770779411614440863872580331681887247489622411";
      "11578979089604924419672152758230524155578424562011333797269885929442680042317";
      "50413588594256908654341963895371964591208017449187726872226940257366479794931";
      "25342645262500526730472670090219790271213097305995599586909134601382438580057";
      "8823851208157208211075893000112820438603010547555640271936182343488623715695";
      "48715166069588125017688857080421400882110756555551531562607166243928305121118";
      "457928742693316582022794368629361528074764749146022984852066320975235063636";
      "40784591676918140113004512439228960581998583153376036451231191678625605644121";
      "18433242804842005502998987143284711404363511412515282751547329224013759991670";
      "13389179080347763657382998600872902733061029331254291204270991952891409570918";
      "50192764209384080101272306620889875080455867628520281400927714930481563250325";
      "21188812847528225766555643216406799500549004969671500977130541863203997121380";
      "15467310814359095588985846207322319122950649805677111326687390171860927014900";
      "43568129081901200261103456211527409151200730655566657378341556085992472943958";
      "34271132631203889901701300408318058004416254071247236806623005223769350150039";
      "22173004425756666568314241635854763913339665884248599814793658197582222664954";
      "32975563242070450354147568749607182665869459510325615902750312087436132984686";
      "22696762757124796424578806530049133427552572655901519744413916679979764071390";
      "17763704296411643970998432037239004006015355463277677435659459899409343551392";
      "47107020014905029302099526236973268575042805085389783842994685212684421454488";
      "13304672766482627838923613214260444961210749299235217922669168410578113120633";
      "14336471400558675842362782084319960764287611922882892949544609123042059062824";
      "19303757685423427260649409150012846414071844305131989213305575732858057757894";
      "41105909312432760443399922527873622836019389621682258300053074843930035806751";
      "4449965847617470660026263611722341184463318026296894969809166330782012760219";
      "31939993490530073679397065723723444395703645080257573290017499883874398700446";
      "44612014630702294701797504988969181620837907283197659821551486351788471559337";
      "42992712381319065313644044212157260265940162092852802442073735607198967462282";
      "966835047744911231490794763166379188555949592683359886287393788918898119684";
    |]
    |> Array.map Bls12_381.Fr.of_string

  let security_128_state_size_3 =
    {
      nb_of_rounds = 14;
      state_size = 3;
      linear_layer = state_size_3_mds;
      round_constants = state_size_3_round_constants;
    }
end

type parameters = Parameters.t

type ctxt = Stubs.ctxt

let allocate_ctxt parameters =
  let open Parameters in
  if parameters.state_size <> 3 then
    failwith "Only suppporting state size of 3 at the moment" ;
  Stubs.allocate_ctxt
    parameters.linear_layer
    parameters.round_constants
    parameters.nb_of_rounds
    parameters.state_size

let apply_permutation ctxt = Stubs.apply_permutation ctxt

let set_state ctxt state =
  let exp_state_size = Stubs.get_state_size ctxt in
  let state_size = Array.length state in
  if state_size <> exp_state_size then
    failwith
      (Printf.sprintf
         "The given array contains %d elements but the expected state size is \
          %d"
         state_size
         exp_state_size) ;
  Stubs.set_state ctxt state

let get_state_size ctxt = Stubs.get_state_size ctxt

let get_state ctxt =
  let state_size = Stubs.get_state_size ctxt in
  let state = Array.init state_size (fun _ -> Bls12_381.Fr.(copy zero)) in
  Stubs.get_state state ctxt ;
  state
