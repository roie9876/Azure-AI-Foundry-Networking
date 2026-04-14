param projectWorkspaceId string

var part1 = substring(projectWorkspaceId, 0, 8)
var part2 = substring(projectWorkspaceId, 8, 4)
var part3 = substring(projectWorkspaceId, 12, 4)
var part4 = substring(projectWorkspaceId, 16, 4)
var part5 = substring(projectWorkspaceId, 20, 12)

var formattedGuid = '${part1}-${part2}-${part3}-${part4}-${part5}'

output projectWorkspaceIdGuid string = formattedGuid
