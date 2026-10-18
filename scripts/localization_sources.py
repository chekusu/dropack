"""Read ordinary Swift string literals, preserving interpolation source order."""
def strings(s):
 i=0
 while i<len(s):
  if s.startswith('//',i):
   p=s.find('\n',i);i=len(s) if p<0 else p+1;continue
  if s.startswith('/*',i):
   p=s.find('*/',i+2);i=len(s) if p<0 else p+2;continue
  if s[i]!='"':i+=1;continue
  start=i;i+=1;body='';args=[];nested=[]
  while i<len(s):
   if s[i]=='"':i+=1;break
   if s.startswith('\\(',i):
    a=i+2;j=a;depth=1;quoted=False
    while j<len(s):
     if s[j]=='\\':j+=2;continue
     if s[j]=='"':quoted=not quoted
     if not quoted:
      if s[j]=='(':depth+=1
      if s[j]==')':depth-=1
      if depth==0:break
     j+=1
    args.append(s[a:j]);nested.append((a,s[a:j]));body+='%@';i=j+1;continue
   if s[i]=='\\' and i+1<len(s):body+=s[i:i+2];i+=2;continue
   body+=s[i];i+=1
  yield start,i,body,args
  for offset, expression in nested:
   for child_start, child_end, child_body, child_args in strings(expression):
    yield offset+child_start,offset+child_end,child_body,child_args
