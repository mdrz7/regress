#!/bin/bash
#################################################
# GSQL language user management commands        #
# positive and negative test cases              #
# Tester: Chengjie, Jue                         #
# This is the script to test user management    #
# commands.                                     #
# NOTE: Please make sure you clean up after     #
# yourself.                                     #
#                                               #
# Detailed commands tested:                     #
# CREATE USER                                   #
# ALTER PASSWORD [user1]                        #
# CREATE SECRET                                 #
# SHOW SECRET                                   #
# SHOW TOKEN                                    #
# CREATE TOKEN                                  #
# REFRESH TOKEN token1                          #
# DROP TOKEN token1                             #
# GRANT/REVOKE ROLE admin to user1, user2       #
# DROP USER user1                               #
# DROP TOKEN sdfkljdslkj                        #
# DROP SECRET sdfljdsdfjk                       #
#################################################

fresh_start

lifeTimeComparetor() {
  threshold=300
  expectedTime=$1
  actualTime=$(($2-$3))
  diff=$(($expectedTime-$actualTime))
  if [ ${diff#-} -gt $threshold ]; then
    echo "expected $expectedTime, but $actualTime is given"
  else
    echo $expectedTime
  fi
}

echo "[GTEST_IB]"
# create a fake graph schema first, this is needed since rest
# will refuse to serve configuration refresh request when there
# is no schema which causes GSQL takes a long time retrying.
# This part should be removed once the rest is fixed.
gsql "
create vertex company (PRIMARY_ID companyId string, id string compress)
create vertex member (PRIMARY_ID companyId string, id string compress)
create UNDIRECTED Edge member_company (FROM company, TO member)
create graph poc_graph(*)
"
echo "[GTEST_IE]"

# combo test
gsql -g poc_graph "
grant role querywriter to tigergraph
show user
grant role queryreader to tigergraph
show user
revoke role queryreader from tigergraph
show user
revoke role admin from tigergraph
show user"

# create users
echo -e "user1\nuse!r1\nuse!r1\n" | gsql "create user"
echo -e "user2\nuser2\nuser2\n" | gsql "create user"
echo -e "user3\nuser3\nuser3\n" | gsql "create user"
echo -e "user_3\nuser_3\nuser_3\n" | gsql "create user"

# create user negative cases:
# distinct passwords
echo -e "user4\nuser4\nuser5\n" | gsql "create user" || true
# duplicate username
echo -e "user1\nuser1\nuser1\n" | gsql "create user" || true
# non-allowed usernames:
# has special char
echo -e ":user1\nuser1\nuser1\n" | gsql "create user" || true
# has space
echo -e "user1 \nuser1\nuser1\n" | gsql "create user" || true
# use keywords as username
echo -e "admin\nuser1\nuser1\n" | gsql "create user" || true

# show users, check user existence
gsql "show user"

# alter password
echo -e "user2\nuser2\n" | gsql "alter password user1"
echo -e "!ok\$ok_ok\n!ok\$ok_ok\n" | gsql "alter password"
echo -e "!ok\$ok_ok\ntigergraph\ntigergraph\n" | gsql "alter password"

# negative alter password
# non-existing user
echo -e 'blah\nblah\n' | gsql "alter password user4" || true
# different passwords
echo -e "user2\nuser1\n" | gsql "alter password user1" || true

# create and show secret
secret=`gsql -g poc_graph "create secret" | grep "secret" | head -n 1 | cut -d " " -f 3`

# create token
token=$(curl -s -X POST -d "{"secret": "${secret}"}" "localhost:8123/requesttoken" | cut -f 7 -d : | cut -b 2-33)
# create token from file payload
echo "{\"secret\": \"${secret}\"}"  > /tmp/secret.dat
token2=$(curl -s -d @/tmp/secret.dat -X POST "localhost:8123/requesttoken" | cut -f 7 -d : | cut -b 2-33)
curl -s -X POST -d "{\"secret\": \"${secret}\", \"lifetime\": \"1000\"}" "localhost:8123/requesttoken" | grep -oh "Generate new token successfully"
curl -s -X POST -d "{\"secret\": \"${secret}\"}" "localhost:8123/requesttoken" | grep -oh "Generate new token successfully"
echo "{\"secret\": \"${secret}\", \"lifetime\": \"5000\"}" > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X POST "localhost:8123/requesttoken" | grep -o "Generate new token successfully"

# create token positive case:
curl -s -X POST -d "{\"secret\": \"${secret}\", \"lifetime\": \"50000\"}" "localhost:8123/requesttoken" | grep -o "Generate new token successfully"
curl -s -X POST -d "{\"secret\": \"${secret}\"}" "localhost:8123/requesttoken" | grep -o "Generate new token successfully"
echo "{\"secret\": \"${secret}\", \"lifetime\": \"5000\"}" > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X POST "localhost:8123/requesttoken" | grep -o "Generate new token successfully"

# check token timestamp after create
# set lifetime as 1000 minutes
echo "Create token with 60_000 seconds:"
current=`date "+%Y-%m-%d %H:%M:%S"`
timeStamp=`date -d "$current" +%s`
currentTimeStamp=$(((timeStamp*1000+10#`date "+%N"`/1000000)/1000))
operationTimeStamp=$(curl -w "\n" -s -X POST -d "{\"secret\": \"${secret}\", \"lifetime\": \"60000\"}" "localhost:8123/requesttoken"| jq '.expiration')
lifeTimeComparetor 60000 $operationTimeStamp $currentTimeStamp

# omit the lifetime section, default value is 1 month
echo "Create token omit the duration(default for 1 month/2_592_000 seconds):"
current=`date "+%Y-%m-%d %H:%M:%S"`
timeStamp=`date -d "$current" +%s`
currentTimeStamp=$(((timeStamp*1000+10#`date "+%N"`/1000000)/1000))
operationTimeStamp=$(curl -w "\n" -s -X POST -d "{\"secret\": \"${secret}\"}" "localhost:8123/requesttoken" | jq '.expiration')
lifeTimeComparetor 2592000 $operationTimeStamp $currentTimeStamp

# create token negative case:
# wrong secret
curl -s -X POST -d '{"secret": "abcdefg", "lifetime": "1000"}' "localhost:8123/requesttoken"
echo '{"secret": "abcdefg", "lifetime": "1000"}' > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X POST "localhost:8123/requesttoken"
# wrong lifetime
curl -s -X POST -d "{\"secret\": \"${secret}\", \"lifetime\": \"abc\"}" "localhost:8123/requesttoken"
echo "{\"secret\": \"${secret}\", \"lifetime\": \"abc\"}" > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X POST "localhost:8123/requesttoken"

# lifetime larger than config max
echo "[GTEST_IB]"
gadmin config set GSQL.MaxAuthTokenLifeTimeSec 10
gadmin config apply -y
gadmin restart gsql -y
wait_until_gsql_up
echo "[GTEST_IE]"
curl -s -X POST -d "{\"secret\": \"${secret}\", \"lifetime\": \"100\"}" "localhost:8123/requesttoken"
echo "{\"secret\": \"${secret}\", \"lifetime\": \"103\"}" > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X POST "localhost:8123/requesttoken"
# set config back
echo "[GTEST_IB]"
gadmin config set GSQL.MaxAuthTokenLifeTimeSec 0
gadmin config apply -y
gadmin restart gsql -y
wait_until_gsql_up
echo "[GTEST_IE]"

# wrong key
curl -s -X POST -d '{"secret1111": "abcdefg", "lifetime": "1000"}' "localhost:8123/requesttoken"
echo "{\"secret1111\": \"abcdefg\", \"lifetime\": \"10000\"}" > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X POST "localhost:8123/requesttoken"

# refresh token
curl -s -X PUT -d "{\"secret\": \"${secret}\", \"token\": \"${token}\", \"lifetime\": \"99999\"}" "localhost:8123/requesttoken" | grep -o '"error":false'
curl -s -X PUT -d "{\"secret\": \"${secret}\", \"token\": \"${token}\"}" "localhost:8123/requesttoken" | grep -o '"error":false'
curl -s --user tigergraph:tigergraph -X PUT -d "{\"token\": \"${token}\"}" "localhost:8123/requesttoken?" | grep -o '"error":false'
echo "{\"secret\": \"${secret}\", \"token\": \"${token}\"}" > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X PUT "localhost:8123/requesttoken" | grep -o '"error":false'

# check token timestamp after refresh
# set lifetime as 60_000 seconds
echo "Refresh with 60_000 seconds:"
current=`date "+%Y-%m-%d %H:%M:%S"`
timeStamp=`date -d "$current" +%s`
currentTimeStamp=$(((timeStamp*1000+10#`date "+%N"`/1000000)/1000))
operationTimeStamp=$(curl -w "\n" -s -X PUT -d "{\"secret\": \"${secret}\", \"token\": \"${token}\", \"lifetime\": \"60000\"}" "localhost:8123/requesttoken" | jq '.expiration')
lifeTimeComparetor 60000 $operationTimeStamp $currentTimeStamp

# omit the lifetime section, default value is 1 month
echo "Refresh omit the duration(default for 1 month/2_592_000 seconds):"
current=`date "+%Y-%m-%d %H:%M:%S"`
timeStamp=`date -d "$current" +%s`
currentTimeStamp=$(((timeStamp*1000+10#`date "+%N"`/1000000)/1000))
operationTimeStamp=$(curl -w "\n" -s -X PUT -d "{\"secret\": \"${secret}\", \"token\": \"${token}\"}" "localhost:8123/requesttoken" | jq '.expiration')
lifeTimeComparetor 2592000 $operationTimeStamp $currentTimeStamp

# Refresh with 60_000 seconds by username and password
echo "Refresh with 60_000 seconds by username and password:"
current=`date "+%Y-%m-%d %H:%M:%S"`
timeStamp=`date -d "$current" +%s`
currentTimeStamp=$(((timeStamp*1000+10#`date "+%N"`/1000000)/1000))
operationTimeStamp=$(curl -w "\n" --user tigergraph:tigergraph -s -X PUT -d "{\"token\": \"${token}\", \"lifetime\": \"60000\"}" "localhost:8123/requesttoken" | jq '.expiration')
lifeTimeComparetor 60000 $operationTimeStamp $currentTimeStamp

gsql -g poc_graph "grant ROLE querywriter to user3"
tokenU3=$(curl -s --user user3:user3 -X POST -d "{\"graph\": \"poc_graph\"}" "localhost:8123/requesttoken" | jq .results.token | cut -b 2-33)
# negative case: refresh other's token via user without superuser role
curl -s --user user3:user3 -X PUT -d "{\"token\": \"${token}\"}" "localhost:8123/requesttoken" | grep -o 'Refresh token failed, Permission denied.'
# positive case: refresh other's token via user with superuser role
curl -s --user tigergraph:tigergraph -X PUT -d "{\"token\": \"${tokenU3}\"}" "localhost:8123/requesttoken" | grep -o '"error":false'
# negative case: drop other's token via user without superuser role
curl -s --user user3:user3 -X DELETE -d "{\"token\": \"${token}\"}" "localhost:8123/requesttoken" | grep -o '"message":"Drop token failed, Permission denied."'
# positive case: drop other's token while login by username and password
curl -s --user tigergraph:tigergraph -X DELETE -d "{\"token\": \"${tokenU3}\"}" "localhost:8123/requesttoken" | grep -o '"message":"Drop token successfully."'

# refresh token negative
curl -s -X PUT -d "{\"secret\": \"${secret}\", \"token\": \"abc123\", \"lifetime\": \"99999\"}" "localhost:8123/requesttoken"
curl -s -X PUT -d '{"secret": "ssssssssssssss", "token": "abc123"}' "localhost:8123/requesttoken"
echo "{\"secret\": \"${secret}\", \"token\": \"abc1234\", \"lifetime\": \"99999\"}" > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X PUT "localhost:8123/requesttoken"

# drop token positive
curl -s -X DELETE -d "{\"secret\": \"${secret}\", \"token\": \"${token}\"}" "localhost:8123/requesttoken" | grep -o '"message":"Drop token successfully."'
echo "{\"secret\": \"${secret}\", \"token\": \"${token2}\"}" > /tmp/secret.dat
curl -s -X DELETE -d @/tmp/secret.dat "localhost:8123/requesttoken" | grep -o '"message":"Drop token successfully."'

# drop token negative
curl -s -X DELETE -d "{\"secret\": \"${secret}\", \"token\": \"abc123\"}" "localhost:8123/requesttoken"
curl -s -X DELETE -d "{\"secret\": \"ssssssssssssss\", \"token\": \"abc123\"}" "localhost:8123/requesttoken"
echo "{\"secret\": \"${secret}\", \"token\": \"abc123\"}" > /tmp/secret.dat
curl -s -d @/tmp/secret.dat -X DELETE "localhost:8123/requesttoken"

# grant roles
gsql -g poc_graph "grant ROLE admin to user1"
gsql -g poc_graph "grant ROLE designer to user2"
gsql -g poc_graph "grant ROLE querywriter to user2, user1, user3"
gsql -g poc_graph "grant ROLE queryreader to user1, user2, user3"

# verify roles
gsql show user | grep -Ev "Secret|Alias|Token"

# grant roles negative cases
gsql -g poc_graph "grant ROLE abc to user1" || true
gsql -g poc_graph "grant ROLE abc to user1, user2, user9" || true
gsql -g poc_graph "grant ROLE admin to user9" || true
gsql -g poc_graph "grant ROLE admin to user1, user9" || true
# verify
gsql show user | grep -Ev "Secret|Alias|Token"

# revoke roles
gsql -g poc_graph "revoke ROLE admin from user1"
gsql -g poc_graph "revoke ROLE queryreader from user1, user2, user3"

# revoke roles negative cases
gsql -g poc_graph "revoke ROLE admin from user1,user2,user3" || true
gsql -g poc_graph "revoke ROLE querywriter from user4,user2,user3" || true
gsql -g poc_graph "revoke ROLE abc from user1" || true

########################################
# cleaning up ....
########################################
# drop token
curl -s -X DELETE -d "{\"secret\": \"${secret}\", \"token\": \"${token}\"}" "localhost:8123/requesttoken" | grep -oh "doesn't exist"
echo "[GTEST_IB]"
# drop secret
gsql -g poc_graph "drop secret $secret"
echo "[GTEST_IE]"

# drop users
gsql "drop user user1"
gsql "drop user user2,user3"

# drop user negative case:
# drop non-exist user
gsql "drop user user3" || true

# remove file payload
rm /tmp/secret.dat
