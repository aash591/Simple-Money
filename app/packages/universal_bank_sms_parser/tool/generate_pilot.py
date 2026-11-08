import json,pathlib
from source_layout import write_country_source, write_conformance
p=pathlib.Path(__file__).resolve().parent.parent
index=p/'rules/india/country.json'
if index.exists() and len(json.loads(index.read_text(encoding='utf-8-sig'))['banks']) > 4:
 raise SystemExit('Historical pilot generator: expanded bank rules are authoritative; edit those files instead.')
def write(path,data):
 if path.startswith('rules/') and path.endswith('/source.json'):
  write_country_source(path.split('/')[1],data);return
 f=p/path;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def lit(value):return {'op':'match_literal','value':value}
def cap(kind,name,length=64,values=None):
 r={'op':'capture_'+kind,'name':name,'maxLength':length}
 if values:r['values']=values
 return r
def output(account=True,reference=False,party=False,currency=None,denomination=False):
 r={'amount':{'capture':'amount'}}
 if account:r['accountLast4']={'capture':'account','operation':'extract_account_suffix','length':4}
 if reference:r['reference']={'capture':'reference'}
 if party:r['counterparty']={'capture':'party'}
 if currency:r['currency']={'capture':'currency'}
 if denomination:r['amount']['denominationCapture']='denomination'
 return r
def fmt(id,direction,channel,tokens,out,**kw):
 return dict(id=id,classification='completed',direction=direction,channel=channel,tokens=tokens,output=out,**kw)
def bank(id,name,senders,formats,**kw):return dict(id=id,name=name,senders=senders,formats=formats,**kw)
def cls(classification,any,none=None):
 return {'classification':classification,'when':{'any':any,**({'none':none} if none else {})}}
english=[cls('security',['your otp','Your OTP','otp is','verification code','one-time password']),cls('promotional',['apply now','exclusive offer','Exclusive offer','pre-approved','cashback offer']),cls('failed',['failed','declined','unsuccessful']),cls('pending',['pending']),cls('future',['will be debited','Will be debited','will be credited','to be debited','payment due']),cls('notice',['statement generated','minimum amount due'])]
def country(code,currency,banks,**kw):
 return dict(schemaVersion='0.1',minEngineVersion='0.1.0',packVersion=1,country=code,defaults={'currency':currency,'case':'ascii_insensitive','digits':['ascii'],'decimalMark':'.','grouping':'western','exponents':{currency:2}},classifiers=english,banks=banks,**kw)
bandhan=bank('in.bandhan','Bandhan Bank',['BDNSMS','BANDHAN','BANDHN'],[
 fmt('in.bandhan.upi.debit','debit','upi',[lit('INR '),cap('money','amount',24),lit(' debited from A/c '),cap('account','account',32),lit(' towards UPI/DR/'),cap('reference','reference',32),lit('/'),cap('text','party',100),lit(' Value ')],output(reference=True,party=True)),
 fmt('in.bandhan.upi.credit','credit','upi',[lit('INR '),cap('money','amount',24),lit(' deposited to A/c '),cap('account','account',32),lit(' towards UPI/CR/'),cap('reference','reference',32),lit('/'),cap('text','party',100),lit('/')],output(reference=True,party=True))])
idfc=bank('in.idfc','IDFC FIRST Bank',['IDFCBK','IDFCFB','IDFCB','IDFC'],[
 fmt('in.idfc.card','debit','card',[lit('Transaction Successful! '),cap('enum','currency',3,['INR','USD','EUR','GBP']),lit(' '),cap('money','amount',24),lit(' spent on your IDFC FIRST Bank Credit Card ending '),cap('account','account',32),lit(' at '),cap('text','party',100),lit(' on ')],output(party=True,currency=True),defaults={'exponents':{'USD':2,'EUR':2,'GBP':2}}),
 *[fmt('in.idfc.account.'+direction,direction,'bankTransfer',[lit('Your A/C '),cap('account','account',32),lit(' is '+verb+' by INR '),cap('money','amount',24),lit(' on ')],output()) for direction,verb in [('debit','debited'),('credit','credited')]]])
indian=bank('in.indian','Indian Bank',['INDBNK','INDIAN'],[
 fmt('in.indian.credit','credit','bankTransfer',[lit('Your A/c '),cap('account','account',32),lit(' is credited by Rs.'),cap('money','amount',24),lit(' on ')],output())],requires={'none':['IndusInd']})
indus=bank('in.indusind','IndusInd Bank',['INDBNK','INDUSB','INDUSIND'],[
 fmt('in.indusind.upi.credit','credit','upi',[lit('A/C '),cap('account','account',32),lit(' credited by Rs '),cap('money','amount',24),lit(' from '),cap('text','party',100),lit('. RRN:'),cap('reference','reference',32),lit('.')],output(reference=True,party=True))],requires={'all':['IndusInd']})
india=country('IN','INR',[bandhan,idfc,indian,indus]);write('rules/india/source.json',india)
parsian=bank('ir.parsian','Parsian Bank',['PARSIANBANK','PARSIAN','PARSIAN BANK','PERSIANBANK','PERSIAN'],[
 fmt('ir.parsian.'+direction,direction,'bankTransfer',[lit('مبلغ '),cap('money','amount',24),lit(' '),cap('enum','denomination',8,['تومان','ریال']),lit(' '+movement)],output(account=False,denomination=True))
 for direction,movement in [('debit','از حساب شما برداشت شد.'),('credit','واریز به حساب شما انجام شد.')]])
iran=country('IR','IRR',[parsian]);iran['defaults'].update(case='exact',digits=['ascii','persian','arabic_indic'],denominations={'تومان':{'currency':'IRR','multiplier':10},'ریال':{'currency':'IRR','multiplier':1}});iran['classifiers']=english+[cls('security',['رمز یکبار مصرف','کد تایید']),cls('promotional',['پیشنهاد','تبلیغ','تخفیف']),cls('failed',['ناموفق','لغو']),cls('pending',['در انتظار']),cls('future',['درخواست پرداخت'])];write('rules/iran/source.json',iran)
thai=country('TH','THB',[bank('th.bangkok','Bangkok Bank',['BBL'],[
 fmt('th.bangkok.transfer.debit','debit','bankTransfer',[lit('BBL: โอนเงินออก '),cap('money','amount',24),lit(' บาท บช '),cap('account','account',32),lit(' คงเหลือ ')],output(),defaults={'case':'exact','digits':['ascii','thai']})])]);write('rules/thailand/source.json',thai)
fixtures=[]
def fixture(id,sender,body,rule,amount,currency,direction,channel,bank,country,account=None,reference=None,party=None,legacy=True,provenance='existing PennyWise-derived Dart fixture'):
 fixtures.append({'id':id,'provenance':provenance,'input':{'sender':sender,'body':body,'receivedAt':'2026-10-07T00:00:00.000Z'},'expected':{'classification':'completed','decision':'review','reason':'completedNeedsReview','packVersion':1,'ruleId':rule,'candidate':{'amountMinor':amount,'currencyCode':currency,'direction':direction,'channel':channel,'occurredAt':'2026-10-07T00:00:00.000Z','bankName':bank,'countryCode':country,'accountLast4':account,'reference':reference,'counterparty':party}},'compareLegacy':legacy})
fixture('bandhan-debit','XY-BDNSMS-S','INR 180.00 debited from A/c XXXXXXXXXX1234 towards UPI/DR/D123013240123/Amazon Pa Value 16-NOV-2025 . Clear Bal is INR 9999.99. Bandhan Bank','in.bandhan.upi.debit',18000,'INR','debit','upi','Bandhan Bank','IN','1234','D123013240123','Amazon Pa')
fixture('bandhan-credit','XY-BDNSMS-S','INR 25,000.00 deposited to A/c XXXXXXXXXX1234 towards UPI/CR/C224513287910/JOHN DOE/u on 03-OCT-2025 . Clear Bal is INR 30,123.00 . Bandhan Bank.','in.bandhan.upi.credit',2500000,'INR','credit','upi','Bandhan Bank','IN','1234','C224513287910','JOHN DOE')
fixture('idfc-card','BM-IDFCBK-S','Transaction Successful! EUR 500.00 spent on your IDFC FIRST Bank Credit Card ending XX1234 at AMAZON EU on 08-FEB-2025 at 01:28 PM Avbl Limit: INR 4074.10 If not done by you, call 180010888','in.idfc.card',50000,'EUR','debit','card','IDFC FIRST Bank','IN','1234',party='AMAZON EU')
fixture('idfc-debit','BM-IDFCBK-S','Your A/C XXXXXXX1234 is debited by INR 68.00 on 06/08/25 17:36. New Bal :INR 5000.00','in.idfc.account.debit',6800,'INR','debit','bankTransfer','IDFC FIRST Bank','IN','1234')
fixture('idfc-credit','BM-IDFCBK-S','Your A/C XXXXXXX5678 is credited by INR 500.00 on 06/08/25 17:36. New Bal :INR 10000.00','in.idfc.account.credit',50000,'INR','credit','bankTransfer','IDFC FIRST Bank','IN','5678')
fixture('shared-indian','INDBNK','Your A/c XXXXX1234 is credited by Rs.6600.00 on 01-Oct-2026.','in.indian.credit',660000,'INR','credit','bankTransfer','Indian Bank','IN','1234',provenance='source-derived shared-sender conformance example')
fixture('shared-indusind','INDBNK','A/C *XX1234 credited by Rs 25000.00 from xxxx.yyyy@ybl. RRN:510048508040. Avl Bal:105502.12. Not you? Call 18602677777 - IndusInd bank.','in.indusind.upi.credit',2500000,'INR','credit','upi','IndusInd Bank','IN','1234','510048508040','xxxx.yyyy@ybl')
fixtures[-1]['legacyDifferences']={'counterparty':'Rs 25000'}
fixture('parsian-toman-debit','PARSIAN','مبلغ 500,000 تومان از حساب شما برداشت شد. مانده: 2,500,000 تومان','ir.parsian.debit',500000000,'IRR','debit','bankTransfer','Parsian Bank','IR')
fixture('parsian-toman-credit','PARSIANBANK','مبلغ 2,000,000 تومان واریز به حساب شما انجام شد. مانده: 3,000,000 تومان','ir.parsian.credit',2000000000,'IRR','credit','bankTransfer','Parsian Bank','IR')
fixture('thai-transfer','BBL','BBL: โอนเงินออก 1,500.00 บาท บช x1234 คงเหลือ 19,320.45 บาท','th.bangkok.transfer.debit',150000,'THB','debit','bankTransfer','Bangkok Bank','TH','1234')
# Portable behavior extensions are separate from claims of legacy parity.
f=fixtures[7]
fixture('parsian-persian-digits','PARSIAN',f['input']['body'].translate(str.maketrans('0123456789','۰۱۲۳۴۵۶۷۸۹')),'ir.parsian.debit',500000000,'IRR','debit','bankTransfer','Parsian Bank','IR',legacy=False,provenance='digit normalization extension')
fixture('parsian-rial','PARSIAN',f['input']['body'].replace('تومان','ریال'),'ir.parsian.debit',50000000,'IRR','debit','bankTransfer','Parsian Bank','IR')
f=fixtures[2]
fixture('idfc-multiline','BM-IDFCBK-S',f['input']['body'].replace(' at AMAZON','\n at AMAZON').replace('spent on','spent\ton'),'in.idfc.card',50000,'EUR','debit','card','IDFC FIRST Bank','IN','1234',party='AMAZON EU')
for base in list(fixtures):
 if base['id'] in ['parsian-persian-digits','parsian-rial','idfc-multiline']:continue
 for classification,prefix in [('security','Your OTP is 123456. '),('promotional','Exclusive offer: apply now. '),('failed','Payment failed. '),('pending','Payment pending. '),('future','Will be debited. ')]:
  # Case-exact Persian country uses lowercase classifier phrases; make prefixes canonical.
  if base['input']['sender'].startswith('PARSIAN'):prefix=prefix.lower()
  fixtures.append({'id':base['id']+'-'+classification,'input':{**base['input'],'body':prefix+base['input']['body']},'expected':{'classification':classification,'decision':'ignored','reason':classification,'packVersion':1,'ruleId':None,'candidate':None},'compareLegacy':classification!='future','provenance':'conservative future-rejection extension' if classification=='future' else 'adversarial prefix'})
for id,sender,body,reason in [('unknown','UNKNOWN',fixtures[0]['input']['body'],'unregisteredSender'),('balance','BDNSMS','Available balance INR 999.00.','noMatchingFormat'),('malformed-money','BDNSMS',fixtures[0]['input']['body'].replace('180.00','1,80.00'),'noMatchingFormat'),('zero','BDNSMS',fixtures[0]['input']['body'].replace('180.00','0.00'),'noMatchingFormat'),('fraction','BDNSMS',fixtures[0]['input']['body'].replace('180.00','180.001'),'noMatchingFormat'),('promotional-sender','XY-BDNSMS-P',fixtures[0]['input']['body'],'unregisteredSender')]:
 fixtures.append({'id':id,'input':{'sender':sender,'body':body,'receivedAt':'2026-10-07T00:00:00.000Z'},'expected':{'classification':'unknown','decision':'ignored','reason':reason,'packVersion':1,'ruleId':None,'candidate':None},'compareLegacy':False,'provenance':'adversarial conformance example'})
write_conformance(fixtures)
