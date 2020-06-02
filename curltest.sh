#!/bin/bash -v

export AUTH_HEADER='Authorization: Bearer 1072~v2YlFRSHpWOC7Sm8ovy6W5GiDTzlSBc6EDH7CtPKiRje0jH2PAKj7L8C2b0SwxQ4'
export JSON_HEADER='Content-Type:\application/json'

export BASE_URL='https://bcourses.berkeley.edu/api/v1'

# create a quiz
export COURSE_ID=1487863
#echo curl -X POST -H \'$AUTH_HEADER\' -H \'$JSON_HEADER\' -d @quiz.json $BASE_URL/courses/$COURSE_ID/quizzes
curl -H \"$AUTH_HEADER\" -H \"$JSON_HEADER\" $BASE_URL/courses/$COURSE_ID

