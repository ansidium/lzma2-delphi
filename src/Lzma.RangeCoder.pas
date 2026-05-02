unit Lzma.RangeCoder;

interface

uses
  Lzma.Types;

const
  LZMA_TOP_VALUE = UInt32(1) shl 24;
  LZMA_NUM_BIT_MODEL_TOTAL_BITS = 11;
  LZMA_BIT_MODEL_TOTAL = 1 shl LZMA_NUM_BIT_MODEL_TOTAL_BITS;
  LZMA_NUM_MOVE_BITS = 5;
  LZMA_PROB_INIT = LZMA_BIT_MODEL_TOTAL shr 1;

function LzmaProbUpdate0(const Prob: CLzmaProb): CLzmaProb; inline;
function LzmaProbUpdate1(const Prob: CLzmaProb): CLzmaProb; inline;

implementation

function LzmaProbUpdate0(const Prob: CLzmaProb): CLzmaProb;
begin
  Result := CLzmaProb(Prob + ((LZMA_BIT_MODEL_TOTAL - Prob) shr LZMA_NUM_MOVE_BITS));
end;

function LzmaProbUpdate1(const Prob: CLzmaProb): CLzmaProb;
begin
  Result := CLzmaProb(Prob - (Prob shr LZMA_NUM_MOVE_BITS));
end;

end.
