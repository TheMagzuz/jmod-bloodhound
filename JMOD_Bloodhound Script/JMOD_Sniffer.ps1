﻿#networking related, for use in Invoke-Webrequest/RestMethod
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::DnsRefreshTimeout = 0

$netAssembly = [Reflection.Assembly]::GetAssembly([System.Net.Configuration.SettingsSection])

if($netAssembly)
{
    $bindingFlags = [Reflection.BindingFlags] "Static,GetProperty,NonPublic"
    $settingsType = $netAssembly.GetType("System.Net.Configuration.SettingsSectionInternal")

    $instance = $settingsType.InvokeMember("Section", $bindingFlags, $null, $null, @())

    if($instance)
    {
        $bindingFlags = "NonPublic","Instance"
        $useUnsafeHeaderParsingField = $settingsType.GetField("useUnsafeHeaderParsing", $bindingFlags)

        if($useUnsafeHeaderParsingField)
        {
          $useUnsafeHeaderParsingField.SetValue($instance, $true)
        }
    }
}

#end of network related calls

$permaLinksList = New-Object System.Collections.Generic.List[System.Object]

#function get token from reddit to utilize the api
function Get-RedditToken 
{
    $credentials = @{
                        grant_type = "password"
                        username = $Global:username
                        password = $Global:password
                    }
    $Global:token = Invoke-RestMethod -Method Post -Uri "https://www.reddit.com/api/v1/access_token" -Body $credentials -ContentType 'application/x-www-form-urlencoded' -Credential $Global:creds
}

function PostConditionCheck($jmodComments)
{
    if($jmodComments.Count -gt 1)
    {
        #see if comment count is greater than 1 for J-MOD comments
        return $true
    }
    else
    {
        foreach($comment in $jmodComments)
        {
            if(([int]$comment.CommentScore) -le -15)
            {
                #if score is less than or equal to -15, trigger bot
                return $true
            }
        }
    }

    #no conditions reached, returning false for trigger
    return $false
}

#function to search sub-tree comments
function SearchSubComments($commentList)
{
    foreach($subComment in $commentList)
    {
        #if there are more replies underneath this subcomment, recursively search downwards
        if($subComment.replies)
        {
            SearchSubComments -commentList $subComment.replies.data.children.data
        }

        #if comment flair matches our target(s), proceed
        if($subComment.author_flair_css_class -match "jagexmod" -or $subComment.author_flair_css_class -match "modmatk" -or $subComment.author_flair_css_class -match "mod-jagex")
        {
            $payload = @{
                            category = "cached"
                            id = $subComment.name
                        }

                $rawCommentBody = ($subComment.body -split "`n")[0]

                if($rawCommentBody.Length -gt 45)
                {
                    #cut it off with ...
                    $rawCommentBody = $rawCommentBody.Substring(0,45) + "..."
                }
                elseif($rawCommentBody -eq "")
                {
                    $rawCommentBody = "No text found!"
                }
            
            #creating context for the comments if needed
            $commentContext = ""
            if($subComment.depth -gt 0)
            {
                #comment depth is greater than 3, add some context to it
                if($subComment.depth -gt 3)
                {
                    #limit is greater than 3, cap it
                    $commentContext = "?context=3"
                }
                else
                {
                    $commentContext = "?context=" + $subComment.depth
                }
            }

            $global:permaLinksList.Add([pscustomobject]@{'Author' = $subComment.author
            'Title' = $subComment.author_flair_text
            'Permalink' = $subComment.permalink + $commentContext
            'CommentBody' = $rawCommentBody
            'CommentScore' = $subComment.score})

            #if comment is not saved, then save it
            if($subComment.saved -eq $false)
            {
                try
                {
                    $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                }
                catch
                {
                    Write-Host "Token expired, renewing..." -ForegroundColor Red
                    Get-RedditToken #updates token value
                    $header = @{authorization = $global:token.token_type + " " + $global:token.access_token}
                    Write-Host "Renewed Access Code." -ForegroundColor Green

                    $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                }
            }
        }
    }
}

function GetAndPost($infoBlock, $header, $subReddit)
{
    foreach($newsLink in ($infoBlock.data.children.data) | Where {([int]$_.num_comments) -gt 10})
    {
        #list of all permalinks for valid J-MOD comments
        $global:permaLinksList = New-Object System.Collections.Generic.List[System.Object]
        #get post's save status
        $postSavedStatus = $newsLink.saved
        #reddit ID for the post
        $postID = $newsLink.id

        #uri to get all the comments from the post
        $sniffedPostUri = "https://oauth.reddit.com/r/$subReddit/comments/$postID"

        #get the post's interior information (comments)
        try
        {
            $postInfo = Invoke-RestMethod -uri $sniffedPostUri -Method GET -Headers $header -UserAgent $userAgent
        }
        catch
        {
            Write-Host "Token expired, renewing..." -ForegroundColor Red
            Get-RedditToken #updates token value
            $header = @{authorization = $token.token_type + " " + $token.access_token}
            Write-Host "Renewed Access Code." -ForegroundColor Green
    
            $postInfo = Invoke-RestMethod -uri $sniffedPostUri -Method GET -Headers $header -UserAgent $userAgent
        }
        #flag to see if JMOD comment is currently in top 25? top level comments
        $jmodInTopLevel = $false

        #if post was previously touched (saved)
            #assume that the comment's already reached threshold for trigger (low karma or multiple J-MOD posts)

        if($postSavedStatus)
        {
            #foreach comment in the post
            foreach($comment in ($postInfo.data.children | Where {$_.kind -eq "t1"}).data)
            {
                #if comment has replies, search down it further
                if($comment.replies)
                {
                    foreach($subComment in $comment.replies.data.children.data)
                    {
                        SearchSubComments -commentList $subComment
                    }
                }

                #if comment has flair of a J-MOD, then add it to the permalink list and save it
                if($comment.author_flair_css_class -match "jagexmod" -or $comment.author_flair_css_class -match "modmatk" -or $comment.author_flair_css_class -match "mod-jagex")
                {
                    $jmodInTopLevel = $true
                    $payload = @{
                                    category = "cached"
                                    id = $comment.name
                                }

                    $rawCommentBody = ($comment.body -split "`n")[0]

                    if($rawCommentBody.Length -gt 45)
                    {
                        #cut it off with ...
                        $rawCommentBody = $rawCommentBody.Substring(0,45) + "..."
                    }
                    elseif($rawCommentBody -eq "")
                    {
                        $rawCommentBody = "No text found!"
                    }

                    #creating context for the comments if needed
                    $commentContext = ""

                    if($comment.depth -gt 0)
                    {
                        #comment depth is greater than 3, add some context to it
                        if($comment.depth -gt 3)
                        {
                            #limit is greater than 3, cap it
                            $commentContext = "?context=3"
                        }
                        else
                        {
                            $commentContext = "?context=" + $comment.depth
                        }
                    }


                    $global:permaLinksList.Add([pscustomobject]@{'Author' = $comment.author
                    'Title' = $comment.author_flair_text
                    'Permalink' = $comment.permalink + $commentContext
                    'CommentBody' = $rawCommentBody
                    'CommentScore' = $comment.score})

                    #if comment hasn't been saved it
                    if($comment.saved -eq $false)
                    {                
                        try
                        {
                            $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                        }
                        catch
                        {
                            Write-Host "Token expired, renewing..." -ForegroundColor Red
                            Get-RedditToken #updates token value
                            $header = @{authorization = $global:token.token_type + " " + $global:token.access_token}
                            Write-Host "Renewed Access Code." -ForegroundColor Green
    
                            $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                        }
                    }
                }
            }

            #foreach "more" comment in the post
            foreach($moreComment in ($moreCommentsInfo.json.data.things | Where {$_.kind -eq "t1"}).data)
            {
                #if comment has replies, search down it further
                if($moreComment.replies)
                {
                    foreach($subComment in $moreComment.replies.data.children.data)
                    {
                        SearchSubComments -commentList $subComment
                    }
                }

                #if comment has flair of a J-MOD, then add it to the permalink list and save it
                if($moreComment.author_flair_css_class -match "jagexmod" -or $moreComment.author_flair_css_class -match "modmatk" -or $moreComment.author_flair_css_class -match "mod-jagex")
                {
                    $payload = @{
                                    category = "cached"
                                    id = $moreComment.name
                                }

                    $rawCommentBody = ($moreComment.body -split "`n")[0]

                    if($rawCommentBody.Length -gt 45)
                    {
                        #cut it off with ...
                        $rawCommentBody = $rawCommentBody.Substring(0,45) + "..."
                    }
                    elseif($rawCommentBody -eq "")
                    {
                        $rawCommentBody = "No text found!"
                    }

                    #creating context for the comments if needed
                    $commentContext = ""

                    if($moreComment.depth -gt 0)
                    {
                        #comment depth is greater than 3, add some context to it
                        if($moreComment.depth -gt 3)
                        {
                            #limit is greater than 3, cap it
                            $commentContext = "?context=3"
                        }
                        else
                        {
                            $commentContext = "?context=" + $moreComment.depth
                        }
                    }

                    $global:permaLinksList.Add([pscustomobject]@{'Author' = $moreComment.author
                    'Title' = $moreComment.author_flair_text
                    'Permalink' = $moreComment.permalink + $commentContext
                    'CommentBody' = $rawCommentBody
                    'CommentScore' = $moreComment.score})

                    #if comment hasn't been saved it
                    if($moreComment.saved -eq $false)
                    {    
                        try
                        {
                            $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                        }
                        catch
                        {
                            Write-Host "Token expired, renewing..." -ForegroundColor Red
                            Get-RedditToken #updates token value
                            $header = @{authorization = $global:token.token_type + " " + $global:token.access_token}
                            Write-Host "Renewed Access Code." -ForegroundColor Green
    
                            $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                        }
                    }
                }
            }

        }
        else
        {
            #foreach comment in the post with a jagexmod flair
            foreach($comment in ($postInfo.data.children | Where {$_.kind -eq "t1"}).data)
            {
                #if comment has replies, search down it further
                if($comment.replies)
                {
                    foreach($subComment in $comment.replies.data.children.data)
                    {
                        SearchSubComments -commentList $subComment
                    }
                }

                #if comment has flair of a J-MOD, then add it to the permalink list and save it
                if($comment.author_flair_css_class -match "jagexmod" -or $comment.author_flair_css_class -match "modmatk" -or $comment.author_flair_css_class -match "mod-jagex")
                {
                    $jmodInTopLevel = $true
                    $payload = @{
                                    category = "cached"
                                    id = $comment.name
                                }

                    $rawCommentBody = ($comment.body -split "`n")[0]

                    if($rawCommentBody.Length -gt 45)
                    {
                        #cut it off with ...
                        $rawCommentBody = $rawCommentBody.Substring(0,45) + "..."
                    }
                    elseif($rawCommentBody -eq "")
                    {
                        $rawCommentBody = "No text found!"
                    }

                    #creating context for the comments if needed
                    $commentContext = ""
                    if($comment.depth -gt 0)
                    {
                        #comment depth is greater than 3, add some context to it
                        if($comment.depth -gt 3)
                        {
                            #limit is greater than 5, cap it
                            $commentContext = "?context=3"
                        }
                        else
                        {
                            $commentContext = "?context=" + $comment.depth
                        }
                    }

                    $global:permaLinksList.Add([pscustomobject]@{'Author' = $comment.author
                    'Title' = $comment.author_flair_text
                    'Permalink' = $comment.permalink + $commentContext
                    'CommentBody' = $rawCommentBody
                    'CommentScore' = $comment.score})

                    #no need to do safety check for saving, as post hasn't been touched yet (first time visiting this post)
                    try
                    {
                        $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                    }
                    catch
                    {
                        Write-Host "Token expired, renewing..." -ForegroundColor Red
                        Get-RedditToken #updates token value
                        $header = @{authorization = $global:token.token_type + " " + $global:token.access_token}
                        Write-Host "Renewed Access Code." -ForegroundColor Green
    
                        $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                    }
                }
            }

            #foreach "more" comment
            foreach($moreComment in ($moreCommentsInfo.json.data.things | Where {$_.kind -eq "t1"}).data)
            {
                #if comment has replies, search down it further
                if($moreComment.replies)
                {
                    foreach($subComment in $moreComment.replies.data.children.data)
                    {
                        SearchSubComments -commentList $subComment
                    }
                }

                #if comment has flair of a J-MOD, then add it to the permalink list and save it
                if(($moreComment.author_flair_css_class -match "jagexmod" -or $moreComment.author_flair_css_class -match "modmatk" -or $moreComment.author_flair_css_class -match "mod-jagex") -and $moreComment.saved -eq $false)
                {
                    $payload = @{
                                    category = "cached"
                                    id = $moreComment.name
                                }

                    $rawCommentBody = ($moreComment.body -split "`n")[0]

                    if($rawCommentBody.Length -gt 45)
                    {
                        #cut it off with ...
                        $rawCommentBody = $rawCommentBody.Substring(0,45) + "..."
                    }
                    elseif($rawCommentBody -eq "")
                    {
                        $rawCommentBody = "No text found!"
                    }

                    #creating context for the comments if needed
                    $commentContext = ""
                    if($moreComment.depth -gt 0)
                    {
                        #comment depth is greater than 3, add some context to it
                        if($moreComment.depth -gt 3)
                        {
                            #limit is greater than 5, cap it
                            $commentContext = "?context=3"
                        }
                        else
                        {
                            $commentContext = "?context=" + $moreComment.depth
                        }
                    }

                    $global:permaLinksList.Add([pscustomobject]@{'Author' = $moreComment.author
                    'Title' = $moreComment.author_flair_text
                    'Permalink' = $moreComment.permalink + $commentContext
                    'CommentBody' = $rawCommentBody
                    'CommentScore' = $moreComment.score})

                    #no need to do safety check for saving, as post hasn't been touched yet (first time visiting this post)
                    try
                    {
                        $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                    }
                    catch
                    {
                        Write-Host "Token expired, renewing..." -ForegroundColor Red
                        Get-RedditToken #updates token value
                        $header = @{authorization = $global:token.token_type + " " + $global:token.access_token}
                        Write-Host "Renewed Access Code." -ForegroundColor Green
    
                        $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $global:header -Body $payload -UserAgent $global:userAgent
                    }
                }
            }
        }

        #now check if the post has valid conditions OR if post has been saved (conditions have been already passed once)
        if((PostConditionCheck -jmodComments $global:permaLinksList) -eq $true -or $postSavedStatus -or !$jmodInTopLevel)
        {
            #if any comments were saved, proceed
            if($global:permaLinksList)
            {
                #sort all linked comments by authors
                $global:permaLinksList = $global:permaLinksList | Sort-Object -Property Author
                $parsedText = "##### Bark bark!`n`nI have found the following **J-Mod** comments in this thread:`n`n"
                $lastAuthor = $null
                $commentCounter = 1

                if($postSavedStatus)
                {
                    #script has touched this post before, append commments to previous post
                        #look for bot's previous comment on this post (which will be saved from previous runs)

                    #TO-DO: DO based on csv storage rather than searching again, will need to implement cleanup so CSV doesn't build up over time
                    $previousPostID = $null
            
                    #lazy-man method of finding old bot comment
                    foreach($comment in ($postInfo.data.children | Where {$_.kind -eq "t1"}).data | Where {$_.saved -eq $true -and $_.author -eq $username.ToLower()})
                    {
                        $previousPostID = $comment.name
                        #break free of comment search once we have match
                        break
                    }

                    #found our bot's post
                    if($previousPostID)
                    {
                        foreach($jmodComment in $global:permaLinksList)
                        {
                            #if J-MOD title doesn't exist, then give them generic title of "J-MOD"
                            if(!$jmodComment.Title)
                            {
                                $jmodComment.Title = "J-Mod"
                            }

                            #if lastAuthor doesn't exist, then this is the first J-MOD comment in the list (don't iterate counter from 1)
                            if(!$lastAuthor)
                            {
                                $parsedText += "**"+$jmodComment.Author+"**`n`n- ["+$jmodComment.CommentBody+"](https://www.reddit.com" + $jmodComment.Permalink +")`n`n"
                                $lastAuthor = $jmodComment.Author
                            }
                            elseif($lastAuthor -ne $jmodComment.Author)
                            {
                                $commentCounter = 1
                                $parsedText += "`n`n**"+$jmodComment.Author+"**`n`n- ["+$jmodComment.CommentBody+"](https://www.reddit.com" + $jmodComment.Permalink +")`n`n"
                                $lastAuthor = $jmodComment.Author
                            }
                            else
                            {
                                #iterate comment counter by one, then append the comment
                                $commentCounter += 1
                                $parsedText += "- ["+$jmodComment.CommentBody+"](https://www.reddit.com" + $jmodComment.Permalink +")`n`n"
                            }
                        }

                        #append marker to end of post
                        $editTime = (Get-Date)
                        $parsedText += "`n&nbsp;`n`n^(**Last edited by bot: $editTime**)`n`n---`n`n^(Hi, I tried my best to find all the J-Mod's comments in this post.)  `n^(Interested to see how I work? See my post) ^[here](https://www.reddit.com/user/JMOD_Bloodhound/comments/8dronr/jmod_bloodhound_bot_github_repository/?ref=share&ref_source=link) ^(for my GitHub repo!)"

                        $payload = @{
                                        api_type = "json"
                                        text = $parsedText
                                        thing_id= $previousPostID
                                    }

                        #edit the post
                        Write-Host "Editing post... $previousPostID"
                        try
                        {
                            $null = Invoke-RestMethod -uri "https://oauth.reddit.com/api/editusertext" -Method Post -Headers $header -Body $payload -UserAgent $userAgent
                        }
                        catch
                        {
                            Write-Host "Token expired, renewing..." -ForegroundColor Red
                            Get-RedditToken #updates token value
                            $header = @{authorization = $token.token_type + " " + $token.access_token}

                            Write-Host "Renewed Access Code." -ForegroundColor Green
                            $null = Invoke-RestMethod -uri "https://oauth.reddit.com/api/editusertext" -Method Post -Headers $header -Body $payload -UserAgent $userAgent
                        }
                    }
                }
                else
                {
                    #post not saved, create new text post
                    foreach($jmodComment in $global:permaLinksList)
                    {
                        #if J-MOD title doesn't exist, then give them generic title of "J-MOD"
                        if(!$jmodComment.Title)
                        {
                            $jmodComment.Title = "J-Mod"
                        }

                        #if lastAuthor doesn't exist, then this is the first J-MOD comment in the list (don't iterate counter from 1)
                        if(!$lastAuthor)
                        {
                            $parsedText += "**"+$jmodComment.Author+"**`n`n- ["+$jmodComment.CommentBody+"](https://www.reddit.com" + $jmodComment.Permalink +")`n`n"
                            $lastAuthor = $jmodComment.Author
                        }
                        elseif($lastAuthor -ne $jmodComment.Author)
                        {
                            $commentCounter = 1
                            $parsedText += "`n`n**"+$jmodComment.Author+"**`n`n- ["+$jmodComment.CommentBody+"](https://www.reddit.com" + $jmodComment.Permalink +")`n`n"
                            $lastAuthor = $jmodComment.Author
                        }
                        else
                        {
                            #iterate comment counter by one, then append the comment
                            $commentCounter += 1
                            $parsedText += "- ["+$jmodComment.CommentBody+"](https://www.reddit.com" + $jmodComment.Permalink +")`n`n"
                        }
                    }
                    #append marker to end of post
                    $editTime = (Get-Date)
                    $parsedText += "`n&nbsp;`n`n^(**Last edited by bot: $editTime**)`n`n---`n`n^(Hi, I tried my best to find all the J-Mod's comments in this post.)  `n^(Interested to see how I work? See my post) ^[here](https://www.reddit.com/user/JMOD_Bloodhound/comments/8dronr/jmod_bloodhound_bot_github_repository/?ref=share&ref_source=link) ^(for my GitHub repo!)"

                    $payload = @{
                                    api_type = "json"
                                    text = $parsedText
                                    thing_id= "t3_$postID"
                                }

                    #comment on the post now
                    Write-Host "Creating comment on... $postID"
                    try
                    {
                        $houndPost = Invoke-RestMethod -uri "https://oauth.reddit.com/api/comment" -Method Post -Headers $header -Body $payload -UserAgent $userAgent
                    }
                    catch
                    {
                        try
                        {
                            $houndPost = Invoke-RestMethod -uri "https://oauth.reddit.com/api/comment" -Method Post -Headers $header -Body $payload -UserAgent $userAgent
                        }
                        catch
                        {
                            Write-Host "Token expired, renewing..." -ForegroundColor Red
                            Get-RedditToken #updates token value
                            $header = @{authorization = $token.token_type + " " + $token.access_token}
                            Write-Host "Renewed Access Code." -ForegroundColor Green
                            $houndPost = Invoke-RestMethod -uri "https://oauth.reddit.com/api/comment" -Method Post -Headers $header -Body $payload -UserAgent $userAgent
                        }
                    }


                    #save newly posted comment
                    $payload = @{
                                    category = "cached"
                                    id = $houndPost.json.data.things.data.name
                                }

                    #save bot's posted comment
                    try
                    {
                        $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $header -Body $payload -UserAgent $userAgent
                    }
                    catch
                    {
                        Write-Host "Token expired, renewing..." -ForegroundColor Red
                        Get-RedditToken #updates token value
                        $header = @{authorization = $token.token_type + " " + $token.access_token}
                        Write-Host "Renewed Access Code." -ForegroundColor Green
    
                        $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $header -Body $payload -UserAgent $userAgent
                    }
                }
            }

            #if post was not saved and there are J-MOD comments
            if($global:permaLinksList -and !$postSavedStatus)      
            { 
                Write-Host "Caching and posting to" $newsLink.title
                $payload = @{
                                category = "cached"
                                id = $newsLink.name
                            }
                try
                {
                    $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $header -Body $payload -UserAgent $userAgent
                }
                catch
                {
                    Write-Host "Token expired, renewing..." -ForegroundColor Red
                    Get-RedditToken #updates token value
                    $header = @{authorization = $token.token_type + " " + $token.access_token}
                    Write-Host "Renewed Access Code." -ForegroundColor Green
                }
           
        
                $saveBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/api/save" -Method POST -Headers $header -Body $payload -UserAgent $userAgent
            }
        }

    }
}

#get token from local .csv
    #then check if it's valid, if not use function
$token = $null
try
{
    $token = (Import-Csv -Path "$PSScriptRoot\tokenCache.csv") 
}
catch
{
    Write-Host "Cached token doesn't exist..."
    Get-RedditToken
}

#import local Reddit API cred .csv file
$credFile = Import-Csv -Path "$PSScriptRoot\redditAPILogin.csv"

#load in creds to obscure them
$username = $credFile.redditUser
$password = $credFile.apiRedditBotPass
$clientID = $credFile.clientID
$userAgent = $credFile.userAgent
$clientSecret = ConvertTo-SecureString ($credFile.clientSecret) -AsPlainText -Force
$creds = New-Object -TypeName System.management.Automation.PSCredential -ArgumentList $clientID, $clientSecret
 
#authorization header
$header = @{authorization = $token.token_type + " " + $token.access_token}

#check if cached token is valid
try
{
    Write-Host "Attempting to see if token is still valid..." -ForegroundColor Yellow
    Invoke-RestMethod -uri "https://oauth.reddit.com/user/$username" -Headers $header -UserAgent $userAgent
}
catch
{
    Write-Host "Token is no longer valid, renewing..." -ForegroundColor Red
    Get-RedditToken #updates token value
    $header = @{authorization = $token.token_type + " " + $token.access_token}
    Write-Host "Renewed Access Code." -ForegroundColor Green
}

#have a search limit of the latest 100 posts on the 2007scape reddit (100 is the upper limit of Reddit's API)
$payload = @{limit = '100'}

#attempt to search the new posts, if fails reattempt to get token (as it may have expired)
    #TO-DO: rewrite this for smarter error checking, but in most cases it will be the token expiring
    #since the script is running once every 5 minutes to check against new posts (and there doesn't seem to be a way to check when a token will expire other than tracking it yourself)
        #we'll just do a lazy try-catch for each API call

$searchBlock = $null
try
{
    $searchBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/r/2007scape/hot" -Method Get -Headers $header -Body $payload -UserAgent $userAgent
}
catch
{
    Write-Host "Token expired, renewing..." -ForegroundColor Red
    Get-RedditToken #updates token value
    $header = @{authorization = $token.token_type + " " + $token.access_token}
    Write-Host "Renewed Access Code." -ForegroundColor Green
    
    $searchBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/r/2007scape/hot" -Method Get -Headers $header -Body $payload -UserAgent $userAgent
}

#go through each news post with a "J-MOD reply" flair for r/2007scape
GetAndPost -infoBlock $searchBlock -header $header -subReddit "2007scape"

$searchBlock = $null
try
{
    $searchBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/r/runescape/hot" -Method Get -Headers $header -Body $payload -UserAgent $userAgent
}
catch
{
    Write-Host "Token expired, renewing..." -ForegroundColor Red
    Get-RedditToken #updates token value
    $header = @{authorization = $token.token_type + " " + $token.access_token}
    Write-Host "Renewed Access Code." -ForegroundColor Green
    
    $searchBlock = Invoke-RestMethod -uri "https://oauth.reddit.com/r/runescape/hot" -Method Get -Headers $header -Body $payload -UserAgent $userAgent
}

#go through each news post with a "J-MOD reply" flair for r/runescape
GetAndPost -infoBlock $searchBlock -header $header -subReddit "runescape"

#export latest token to local csv file
$token | Export-Csv -Path "$PSScriptRoot\tokenCache.csv" -NoTypeInformation