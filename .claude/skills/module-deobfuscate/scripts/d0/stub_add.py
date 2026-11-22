import uuid,os,sys
name=sys.argv[1]
tpl=open('stub_ОбщийМодуль.xml',encoding='utf-8-sig').read()
u=str(uuid.uuid4())
x=tpl.replace('e64c2d81-0967-40c1-ade2-c153133ada15',u).replace('ОбщийМодуль',name)
open(f'cf_check/CommonModules/{name}.xml','w',encoding='utf-8-sig',newline='\n').write(x)
os.makedirs(f'cf_check/CommonModules/{name}/Ext',exist_ok=True)
open(f'cf_check/CommonModules/{name}/Ext/Module.bsl','w',encoding='utf-8-sig').write('')
t=open('cf_check/ConfigDumpInfo.xml',encoding='utf-8-sig').read()
ins=('\t<Metadata name="CommonModule.%s" id="%s" configVersion="%s"/>\n' % (name,u,uuid.uuid4().hex+'00000000')) + ('\t<Metadata name="CommonModule.%s.Module" id="%s.0" configVersion="%s"/>\n' % (name,u,uuid.uuid4().hex+'00000000'))
open('cf_check/ConfigDumpInfo.xml','w',encoding='utf-8-sig',newline='\n').write(t.replace('\t</ConfigVersions>', ins+'\t</ConfigVersions>'))
print('stub',name)
