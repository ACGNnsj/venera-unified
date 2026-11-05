p='.github/workflows/analyze.yml'
s=open(p,encoding='utf-8').read()
old='          flutter test --coverage\n          --coverage-path'
new='          flutter test --coverage\n          -j 6\n          --coverage-path'
assert s.count(old)==1, s.count(old)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
print('patched')
