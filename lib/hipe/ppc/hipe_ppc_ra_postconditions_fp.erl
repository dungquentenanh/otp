%% -*- erlang-indent-level: 2 -*-
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(hipe_ppc_ra_postconditions_fp).
-export([check_and_rewrite/2]).
-include("hipe_ppc.hrl").

check_and_rewrite(CFG, Coloring) ->
  TempMap = hipe_temp_map:cols2tuple(Coloring, hipe_ppc_specific_fp, no_context),
  do_bbs(hipe_ppc_cfg:labels(CFG), TempMap, CFG, false).

do_bbs([], _TempMap, CFG, DidSpill) -> {CFG, DidSpill};
do_bbs([Lbl|Lbls], TempMap, CFG0, DidSpill0) ->
  Code0 = hipe_bb:code(BB = hipe_ppc_cfg:bb(CFG0, Lbl)),
  {Code, DidSpill} = do_insns(Code0, TempMap, [], DidSpill0),
  CFG = hipe_ppc_cfg:bb_add(CFG0, Lbl, hipe_bb:code_update(BB, Code)),
  do_bbs(Lbls, TempMap, CFG, DidSpill).

do_insns([I|Insns], TempMap, Accum, DidSpill0) ->
  {NewIs, DidSpill1} = do_insn(I, TempMap),
  do_insns(Insns, TempMap, lists:reverse(NewIs, Accum), DidSpill0 or DidSpill1);
do_insns([], _TempMap, Accum, DidSpill) ->
  {lists:reverse(Accum), DidSpill}.

do_insn(I, TempMap) ->
  case I of
    #lfd{} -> do_lfd(I, TempMap);
    #lfdx{} -> do_lfdx(I, TempMap);
    #stfd{} -> do_stfd(I, TempMap);
    #stfdx{} -> do_stfdx(I, TempMap);
    #fp_binary{} -> do_fp_binary(I, TempMap);
    #fp_unary{} -> do_fp_unary(I, TempMap);
    #pseudo_fmove{} -> do_pseudo_fmove(I, TempMap);
    #pseudo_spill_fmove{} -> do_pseudo_spill_fmove(I, TempMap);
    _ -> {[I], false}
  end.

%%% Fix relevant instruction types.

do_lfd(I=#lfd{dst=Dst}, TempMap) ->
  {FixDst, NewDst, DidSpill} = fix_dst(Dst, TempMap),
  NewI = I#lfd{dst=NewDst},
  {[NewI | FixDst], DidSpill}.

do_lfdx(I=#lfdx{dst=Dst}, TempMap) ->
  {FixDst, NewDst, DidSpill} = fix_dst(Dst, TempMap),
  NewI = I#lfdx{dst=NewDst},
  {[NewI | FixDst], DidSpill}.

do_stfd(I=#stfd{src=Src}, TempMap) ->
  {FixSrc, NewSrc, DidSpill} = fix_src(Src, TempMap),
  NewI = I#stfd{src=NewSrc},
  {FixSrc ++ [NewI], DidSpill}.

do_stfdx(I=#stfdx{src=Src}, TempMap) ->
  {FixSrc, NewSrc, DidSpill} = fix_src(Src, TempMap),
  NewI = I#stfdx{src=NewSrc},
  {FixSrc ++ [NewI], DidSpill}.

do_fp_binary(I=#fp_binary{dst=Dst,src1=Src1,src2=Src2}, TempMap) ->
  {FixDst,NewDst,DidSpill1} = fix_dst(Dst, TempMap),
  {FixSrc1,NewSrc1,DidSpill2} = fix_src(Src1, TempMap),
  {FixSrc2,NewSrc2,DidSpill3} = fix_src(Src2, TempMap),
  NewI = I#fp_binary{dst=NewDst,src1=NewSrc1,src2=NewSrc2},
  {FixSrc1 ++ FixSrc2 ++ [NewI | FixDst], DidSpill1 or DidSpill2 or DidSpill3}.

do_fp_unary(I=#fp_unary{dst=Dst,src=Src}, TempMap) ->
  {FixDst,NewDst,DidSpill1} = fix_dst(Dst, TempMap),
  {FixSrc,NewSrc,DidSpill2} = fix_src(Src, TempMap),
  NewI = I#fp_unary{dst=NewDst,src=NewSrc},
  {FixSrc ++ [NewI | FixDst], DidSpill1 or DidSpill2}.

do_pseudo_fmove(I=#pseudo_fmove{dst=Dst,src=Src}, TempMap) ->
  case temp_is_spilled(Src, TempMap)
    andalso temp_is_spilled(Dst, TempMap)
  of
    true -> % Turn into pseudo_spill_fmove
      Temp = clone(Src),
      NewI = #pseudo_spill_fmove{dst=Dst,temp=Temp,src=Src},
      {[NewI], true};
    _ ->
      {[I], false}
  end.

do_pseudo_spill_fmove(I=#pseudo_spill_fmove{temp=Temp}, TempMap) ->
  %% Temp is above the low water mark and must not have been spilled
  false = temp_is_spilled(Temp, TempMap),
  {[I], false}.

%%% Fix Dst and Src operands.

fix_src(Src, TempMap) ->
  case temp_is_spilled(Src, TempMap) of
    true ->
      NewSrc = clone(Src),
      {[hipe_ppc:mk_pseudo_fmove(NewSrc, Src)], NewSrc, true};
    _ ->
      {[], Src, false}
  end.

fix_dst(Dst, TempMap) ->
  case temp_is_spilled(Dst, TempMap) of
    true ->
      NewDst = clone(Dst),
      {[hipe_ppc:mk_pseudo_fmove(Dst, NewDst)], NewDst, true};
    _ ->
      {[], Dst, false}
  end.

%%% Check if an operand is a pseudo-temp.

temp_is_spilled(Temp, TempMap) ->
  case hipe_ppc:temp_is_allocatable(Temp) of
    true ->
      Reg = hipe_ppc:temp_reg(Temp),
      tuple_size(TempMap) > Reg andalso hipe_temp_map:is_spilled(Reg, TempMap);
    false -> true
  end.

%%% Create a new temp with the same type as an old one.

clone(Temp) ->
  Type = hipe_ppc:temp_type(Temp),	% XXX: always double?
  hipe_ppc:mk_new_temp(Type).
