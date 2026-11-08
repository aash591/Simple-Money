import json,pathlib
p=pathlib.Path(__file__).resolve().parent.parent/'spec';p.mkdir(exist_ok=True)
def write(name,data):(p/name).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def obj(props,required=None,**kw):return {'type':'object','properties':props,'required':required if required is not None else list(props),'additionalProperties':False,**kw}
def ref(name):return {'$ref':'#/$defs/'+name}
def arr(items,max=32,min=0):return {'type':'array','items':items,'maxItems':max,'minItems':min}
string={'type':'string','minLength':1,'maxLength':512}
id={**string,'pattern':'^[a-z][a-zA-Z0-9_.-]*$'}
currency={'type':'string','pattern':'^[A-Z]{3}$'}
classes=['completed','security','promotional','failed','pending','future','notice','unknown']
selector=obj({k:arr(string) for k in ['all','any','none']},[])
classifier=obj({'classification':{'enum':classes[1:-1]},'when':ref('selector')})
selector['description']='All and any are positive predicates; none vetoes. Classifiers require at least one positive literal.'
defaults=obj({'currency':currency,'case':{'enum':['exact','ascii_insensitive']},'digits':{**arr({'enum':['ascii','persian','arabic_indic','thai']},4,1),'uniqueItems':True,'contains':{'const':'ascii'}},'decimalMark':{'enum':['.',',']},'grouping':{'enum':['none','western','indian']},'exponents':{'type':'object','maxProperties':64,'patternProperties':{'^[A-Z]{3}$':{'type':'integer','minimum':0,'maximum':3}},'additionalProperties':False},'denominations':{'type':'object','maxProperties':32,'additionalProperties':obj({'currency':currency,'multiplier':{'type':'integer','minimum':1,'maximum':1000000}})}},[])
end=obj({'op':{'const':'match_end'}})
literal=obj({'op':{'const':'match_literal'},'value':string})
captureName={'type':'string','pattern':'^[a-z][a-zA-Z0-9_]{0,31}$'}
capture=obj({'op':{'enum':['capture_money','capture_reference','capture_number','capture_datetime']},'name':captureName,'maxLength':{'type':'integer','minimum':1,'maximum':256}})
text_capture=obj({'op':{'const':'capture_text'},'name':captureName,'maxLength':{'type':'integer','minimum':1,'maximum':256},'excludeCharacters':string,'rejectDateTime':{'type':'boolean'}},['op','name','maxLength'])
account=obj({'op':{'const':'capture_account'},'name':captureName,'maxLength':{'type':'integer','minimum':1,'maximum':256},'minDigits':{'type':'integer','minimum':1,'maximum':4}},['op','name','maxLength'])
enum=obj({'op':{'const':'capture_enum'},'name':captureName,'maxLength':{'type':'integer','minimum':1,'maximum':256},'values':{**arr(string,32,1),'uniqueItems':True}})
binding={'oneOf':[obj({'value':string}),obj({'capture':captureName})]}
text_binding={'oneOf':[obj({'value':string,'prefix':string},['value']),obj({'capture':captureName,'prefix':string},['capture'])]}
output=obj({'amount':obj({'capture':captureName,'denominationCapture':captureName},['capture']),'currency':ref('binding'),'accountLast4':obj({'capture':captureName,'operation':{'const':'extract_account_suffix'},'length':{'const':4},'allowShort':{'type':'boolean'},'preserveMask':{'type':'boolean'}},['capture','operation','length']),'reference':ref('textBinding'),'counterparty':ref('textBinding')},['amount'])
formatProps={'id':id,'defaults':ref('defaults'),'requires':ref('selector'),'classifiers':arr(ref('classifier'),64),'classification':{'const':'completed'},'direction':{'enum':['debit','credit']},'channel':{'enum':['atm','upi','card','bankTransfer','wallet','other']},'tokens':arr(ref('token'),48,3),'output':ref('output')}
format=obj(formatProps,['id','classification','direction','channel','tokens','output'])
senders={**arr({'type':'string','minLength':1,'maxLength':31,'pattern':'^(?:[A-Z][A-Z0-9_ -]{2,30}|[0-9]+)$'},64,1),'uniqueItems':True}
formatProps['senders']=senders
bank=obj({'id':id,'name':string,'senders':senders,'defaults':ref('defaults'),'requires':ref('selector'),'classifiers':arr(ref('classifier'),64),'formats':arr(ref('format'),4096,1)},['id','name','senders','formats'])
priority={'type':'integer','minimum':0,'maximum':100000}
categoryProps={'id':id,'priority':priority,'directions':arr({'enum':['debit','credit']},2,1),'channels':arr(formatProps['channel'],6,1),'source':{'enum':['body','merchant']},'match':{'enum':['substring','words','exact']},'when':ref('selector'),'requires':ref('selector'),'categoryId':{'type':'string','pattern':'^[a-z][a-z0-9_]*$'},'name':string,'aliases':arr(string,16),'isFallback':{'type':'boolean'}}
categoryRule=obj(categoryProps,['id','priority','directions','source','match','when','categoryId','name'])
nameProps={'id':id,'priority':priority,'prefix':{'type':'string','minLength':1,'maxLength':128},'suffixes':arr({'type':'string','minLength':1,'maxLength':128},16,1),'maxLength':{'type':'integer','minimum':1,'maximum':256},'when':ref('selector')}
counterpartyRule=obj(nameProps)
versions={'schemaVersion':{'const':'0.3'},'minEngineVersion':{'type':'string','pattern':'^[0-9]+\\.[0-9]+\\.[0-9]+$'},'packVersion':{'type':'integer','minimum':1,'maximum':9007199254740991}}
defs={'categoryRule':categoryRule,'counterpartyRule':counterpartyRule,'selector':selector,'classifier':classifier,'defaults':defaults,'token':{'oneOf':[literal,end,capture,text_capture,account,enum]},'binding':binding,'textBinding':text_binding,'output':output,'format':format,'bank':bank}
source=obj({**versions,'country':{'type':'string','pattern':'^[A-Z]{2}$'},'defaults':ref('defaults'),'classifiers':arr(ref('classifier'),64),'banks':arr(ref('bank'),4096,1),'categoryRules':arr(ref('categoryRule'),256),'counterpartyRules':arr(ref('counterpartyRule'),256)},list(versions)+['country','defaults','banks'])
source.update({'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:universal-bank-sms-parser:source:0.3','title':'Portable SMS source pack v0.3','$defs':defs});write('rules.schema.json',source)
resolved=obj({**formatProps,'bankId':id,'bankName':string,'country':{'type':'string','pattern':'^[A-Z]{2}$'},'senders':senders,'defaults':obj(defaults['properties'],list(defaults['properties'])),'requires':arr(ref('selector'),2,2),'classifiers':arr(ref('classifier'),64)},['id','bankId','bankName','country','senders','defaults','requires','classifiers','classification','direction','channel','tokens','output'])
resolvedCategory=obj({**categoryProps,'country':{'type':'string','pattern':'^[A-Z]{2}$'}},categoryRule['required']+['country'])
resolvedCounterparty=obj({**nameProps,'country':{'type':'string','pattern':'^[A-Z]{2}$'}})
runtime=obj({'categoryRules':arr(ref('resolvedCategory'),256),'counterpartyRules':arr(ref('resolvedCounterparty'),256),'format':{'const':'sms-rules-runtime'},**versions,'rules':arr(ref('resolvedRule'),4096,1),'senderIndex':{'type':'object','additionalProperties':arr({'type':'integer','minimum':0,'maximum':4095},128,1)} })
runtime.update({'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:universal-bank-sms-parser:runtime:0.3','$defs':{**defs,'resolvedRule':resolved,'resolvedCategory':resolvedCategory,'resolvedCounterparty':resolvedCounterparty}});write('runtime.schema.json',runtime)
nullable={'type':['string','null']}
candidate=obj({'amountMinor':{'type':'integer','minimum':1,'maximum':9007199254740991},'currencyCode':currency,'direction':{'enum':['debit','credit']},'channel':formatProps['channel'],'occurredAt':{'type':'string','format':'date-time'},'bankName':string,'countryCode':{'type':'string','pattern':'^[A-Z]{2}$'},'accountLast4':{'type':['string','null'],'pattern':'^[0-9Xx*#.-]{1,4}$'},'reference':nullable,'counterparty':nullable})
suggestedCategory=obj({'id':categoryProps['categoryId'],'name':string,'type':{'enum':['expense','income']},'ruleId':id,'isFallback':{'type':'boolean'},'aliases':arr(string,16)})
candidate['properties']['category']=ref('suggestedCategory')
result=obj({'classification':{'enum':classes},'decision':{'enum':['review','ignored']},'reason':{'enum':['invalidMessage','unregisteredSender','security','promotional','failed','pending','future','notice','workLimit','noMatchingFormat','ambiguousMatches','completedNeedsReview']},'packVersion':versions['packVersion'],'ruleId':nullable,'candidate':{'oneOf':[{'type':'null'},ref('candidate')]}})
result.update({'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:universal-bank-sms-parser:result:0.3','$defs':{'candidate':candidate,'suggestedCategory':suggestedCategory},'allOf':[{'if':{'properties':{'reason':{'const':'completedNeedsReview'}}},'then':{'properties':{'classification':{'const':'completed'},'decision':{'const':'review'},'candidate':ref('candidate'),'ruleId':string}}},{'if':{'properties':{'decision':{'const':'ignored'}}},'then':{'properties':{'candidate':{'type':'null'},'ruleId':{'type':'null'}}}},{'if':{'properties':{'reason':{'const':'ambiguousMatches'}}},'then':{'properties':{'classification':{'const':'completed'},'decision':{'const':'review'},'candidate':{'type':'null'},'ruleId':{'type':'null'}}}}]});write('result.schema.json',result)
input=obj({'sender':{'type':'string','maxLength':128},'body':{'type':'string','maxLength':4000},'receivedAt':{'type':'string','format':'date-time'}})
input.update({'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:universal-bank-sms-parser:input:0.3'});write('input.schema.json',input)
country_index=json.loads(json.dumps(source))
country_index['$id']='urn:universal-bank-sms-parser:country:0.3'
country_index['title']='Country defaults and bank file index v0.3'
country_index['properties']['banks']=arr({'type':'string','pattern':'^[a-z0-9_-]+/rules\\.json$'},4096,1)
write('country.schema.json',country_index)
write('bank.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:universal-bank-sms-parser:bank:0.3','$ref':'#/$defs/bank','$defs':defs})

