-- Named arrangements fill channel assignments; they do not detect file metadata.
local arrangements={}
local LIST={
  {id='mono',label='Mono',orders={{id='standard',label='Mono',roles={'M'}}}},
  {id='stereo',label='Stereo',orders={{id='standard',label='Left / Right',roles={'L','R'}}}},
  {id='2.1',label='2.1',orders={{id='standard',label='L R LFE',roles={'L','R','LFE'}}}},
  {id='lcr',label='LCR',orders={{id='film',label='Film',roles={'L','C','R'}},
    {id='wav',label='WAV',roles={'L','R','C'}}}},
  {id='3.1',label='3.1',orders={{id='standard',label='L R C LFE',roles={'L','R','C','LFE'}}}},
  {id='4.0',label='4.0 Surround',orders={{id='standard',label='L R Ls Rs',roles={'L','R','Ls','Rs'}}}},
  {id='lcrs',label='LCRS',orders={{id='film',label='Film',roles={'L','C','R','Cs'}},
    {id='wav',label='WAV',roles={'L','R','C','Cs'}}}},
  {id='quad',label='Quad',orders={{id='standard',label='L R Lrs Rrs',roles={'L45','R45','Lrs','Rrs'}}}},
  {id='4.1',label='4.1',orders={{id='standard',label='L R LFE Ls Rs',roles={'L','R','LFE','Ls','Rs'}}}},
  {id='5.0',label='5.0',orders={{id='standard',label='L R C Ls Rs',roles={'L','R','C','Ls','Rs'}}}},
  {id='5.1',label='5.1',orders={
    {id='wav',label='WAV / SMPTE',roles={'L','R','C','LFE','Ls','Rs'}},
    {id='film',label='Film',roles={'L','C','R','Ls','Rs','LFE'}},
  }},
  {id='6.1',label='6.1',orders={{id='standard',label='L R C LFE Cs Ls Rs',roles={'L','R','C','LFE','Cs','Ls','Rs'}}}},
  {id='7.0',label='7.0',orders={{id='standard',label='L R C Lrs Rrs Lss Rss',roles={'L','R','C','Lrs','Rrs','Lss','Rss'}}}},
  {id='5.1.2',label='5.1.2',orders={{id='standard',label='Top Middle',roles={'L','R','C','LFE','Ls','Rs','Tsl','Tsr'}}}},
  {id='7.1',label='7.1',orders={
    {id='wav',label='WAV / BWF',roles={'L','R','C','LFE','Lrs','Rrs','Lss','Rss'}},
    {id='smpte',label='SMPTE',roles={'L','R','C','LFE','Lss','Rss','Lrs','Rrs'}},
    {id='film',label='Film',roles={'L','C','R','Lss','Rss','Lrs','Rrs','LFE'}},
  }},
}
local BY_ID={}
for _,item in ipairs(LIST) do
  item.count=#item.orders[1].roles
  BY_ID[item.id]=item
end
function arrangements.list(count,project)
  local result={}
  for _,item in ipairs(LIST) do
    if item.count==count or project and item.count<=count then result[#result+1]=item end
  end
  return result
end
function arrangements.get(id,order_id)
  local item=BY_ID[id]
  if not item then return nil end
  if not order_id then return item,item.orders[1] end
  for _,order in ipairs(item.orders) do if order.id==order_id then return item,order end end
end
function arrangements.identify(roles)
  local signature=table.concat(roles,',')
  for _,item in ipairs(LIST) do
    for _,order in ipairs(item.orders) do
      if table.concat(order.roles,',')==signature then return item,order end
    end
  end
end
return arrangements
